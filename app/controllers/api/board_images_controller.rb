class API::BoardImagesController < API::ApplicationController
  respond_to :json
  before_action :set_board_image, only: %i[ show ]
  before_action :set_owned_board_image, only: %i[ update destroy create_image_variation create_image_edit set_current_audio attach_youtube_video upload_video clear_video ]
  before_action :check_board_image_editable!, only: %i[ save_layout set_current_audio update update_multiple remove_multiple create_image_edit create_image_variation upload_audio reset_audio move destroy attach_youtube_video upload_video clear_video ]

  # Extension used for the stored blob, keyed by the uploaded content type.
  # Only covers types in BoardImage.accepted_video_content_types — anything
  # else is rejected before this is consulted.
  VIDEO_UPLOAD_EXTENSIONS = {
    "video/mp4" => "mp4",
    "video/webm" => "webm",
    "video/quicktime" => "mov",
  }.freeze

  # GET /board_images or /board_images.json
  def index
    @board_images = BoardImage.all
  end

  # GET /board_images/1 or /board_images/1.json
  def show
    render json: @board_image.api_view(current_user)
  end

  def save_layout
    @board_image = owned_board_image
    layout = params[:layout]
    screen_size = params[:screen_size]
    @board_image.update_layout(layout, screen_size)
    render json: @board_image.api_view(current_user)
  end

  def set_current_audio
    # @board_image is loaded owner-scoped by set_owned_board_image.
    if @board_image.update(audio_url: board_image_params[:audio_url], voice: board_image_params[:voice])
      render json: @board_image.api_view(current_user)
    else
      Rails.logger.error "Failed to set current audio for BoardImage ID: #{params[:id]} - #{@board_image.errors.full_messages}"
      render json: @board_image.errors, status: :unprocessable_content
    end
  end

  # PATCH/PUT /board_images/1 or /board_images/1.json
  def update
    data = params[:board_image][:data]
    # The "video" key is only writable through the dedicated, validated
    # actions below (attach_youtube_video / upload_video / clear_video).
    # Stripping it here means a generic update can neither inject an
    # unvalidated video config nor clobber an existing one.
    data = data.except(:video) if data.respond_to?(:except)
    updatedData = @board_image.data.merge(data.to_unsafe_h) if data

    @board_image.data = updatedData if updatedData
    @board_image.status = "updated"
    if @board_image.update(board_image_params)
      @board = @board_image.board
      @board.broadcast_board_update!
      render json: @board_image.api_view(current_user)
    else
      render json: @board_image.errors, status: :unprocessable_content
    end
  end

  def update_multiple
    board_image_ids = params[:board_image_ids]
    @board = Board.includes(:board_images).find(params[:board_id])
    if @board.nil?
      render json: { error: "Board not found" }, status: :unprocessable_content
      return
    end
    payload = params[:payload]
    if payload.nil?
      render json: { error: "No payload provided" }, status: :unprocessable_content
      return
    end
    layout_updates = payload[:layout_updates] if payload[:layout_updates]
    if layout_updates && board_image_ids.nil?
      board_image_ids = layout_updates.map { |item| item[:board_image_id].to_i }.compact
    end
    if board_image_ids.nil? || board_image_ids.empty?
      render json: { error: "No board image IDs provided" }, status: :unprocessable_content
      return
    end
    board_images = @board.board_images.where(id: board_image_ids)

    bg_color = payload[:bg_color] if payload[:bg_color]
    border_color = payload[:border_color] if payload[:border_color]
    border_width = payload[:border_width] if payload[:border_width]
    border_radius = payload[:border_radius] if payload[:border_radius]
    update_borders = payload[:update_borders] if payload[:update_borders]
    text_color = payload[:text_color] if payload[:text_color]
    hide_images = payload[:hide_images] if payload[:hide_images]
    hide_labels = payload[:hide_labels] if payload[:hide_labels]
    make_static = payload[:make_static] if payload[:make_static]
    new_board_name = payload[:new_board_name] if payload[:new_board_name]
    create_new_board = payload[:create_new_board] || !new_board_name.blank?
    layout_updates = payload[:layout_updates] if payload[:layout_updates]
    update_to_default_doc = payload[:update_to_default_doc] if payload[:update_to_default_doc]
    # Bulk display-label case transform: "upper", "lower", or "sentence".
    label_case = payload[:label_case].to_s if payload[:label_case].present?

    if create_new_board
      new_board_name ||= "New Board"
      new_board = Board.create(name: new_board_name, user: current_user, parent_id: @board.id, parent_type: "Board")
    end
    results = []
    first_board_image = board_images.first
    first_image = first_board_image&.image
    if create_new_board && new_board
      new_board.display_image_url = first_image.display_image_url(current_user) if first_image
    end

    board_images.each do |board_image|
      if create_new_board && new_board
        new_board.add_image(board_image.image_id)
      end
      if update_to_default_doc
        new_url = board_image.default_doc_url
        Rails.logger.info "Updating BoardImage ID #{board_image.id} to default doc URL: #{new_url}"
        board_image.display_image_url = new_url
      end
      if !bg_color.blank?
        board_image.bg_color = bg_color
      end
      if !text_color.blank?
        board_image.text_color = text_color
      end
      if !border_color.blank? && update_borders
        board_image.border_color = border_color
      end
      if !border_width.blank? && update_borders
        board_image.border_width = border_width
      end
      if !border_radius.blank? && update_borders
        board_image.border_radius = border_radius
      end
      if hide_labels
        board_image.data ||= {}
        board_image.data["hide_label"] = true
      else
        if board_image.data && board_image.data["hide_label"] == true
          board_image.data["hide_label"] = false
        end
      end
      if hide_images
        board_image.hidden = true
      else
        board_image.hidden = false
      end
      if make_static
        board_image.predictive_board_id = nil
      end
      if label_case
        source = board_image.display_label.presence || board_image.label
        transformed = transform_label_case(source, label_case)
        board_image.display_label = transformed if transformed.present?
      end

      layout_to_update = layout_updates.find { |update| update["board_image_id"].to_i == board_image.id } if layout_updates

      screen_size = layout_to_update ? layout_to_update["screen_size"] : nil

      if layout_to_update && screen_size
        board_image.layout[screen_size] = { x: layout_to_update["x"], y: layout_to_update["y"], w: layout_to_update["w"], h: layout_to_update["h"], id: board_image.id.to_s }
      end

      if board_image.save
        results << true
      else
        Rails.logger.error "Failed to update BoardImage ID: #{board_image.id} - #{board_image.errors.full_messages}"
        results << false
      end
    end
    # @board.touch
    # @board.reload
    if create_new_board && new_board
      new_board.reset_layouts
    end

    if results.all?
      @board.broadcast_board_update!
      render json: { board: @board.api_view_with_predictive_images(current_user, true) }
    else
      render json: { error: "Failed to update some board images" }, status: :unprocessable_content
    end
  end

  def remove_multiple
    board_image_ids = params[:board_image_ids]
    @board = Board.find(params[:board_id])
    if @board.nil?
      render json: { error: "Board not found" }, status: :unprocessable_content
      return
    end
    board_images = BoardImage.where(id: board_image_ids, board_id: @board.id)
    if board_images.empty?
      render json: { error: "No board images found" }, status: :unprocessable_content
      return
    end
    results = []
    board_images.each do |board_image|
      if board_image.destroy
        results << true
      else
        results << false
      end
    end
    if results.all?
      @board.broadcast_board_update!
      render json: { board: @board.api_view_with_predictive_images(current_user, true) }
    else
      render json: { error: "Failed to remove some board images" }, status: :unprocessable_content
    end
  end

  def create_image_edit
    # @board_image is loaded owner-scoped by set_owned_board_image.
    begin
      return unless check_credits!(feature_key: "image_edit", feature_name: "AI Image Edits")
      prompt = params[:prompt] || ""
      transparent_background = params[:transparent_background] == "true"
      EditBoardImageJob.perform_async(@board_image.id, prompt, transparent_background)
    rescue => e
      Rails.logger.error "Error while creating image edit for BoardImage ID #{@board_image.id}: #{e.message}"
      render json: { error: "Failed to create image edit" }, status: :unprocessable_content
      return
    end

    @board_image.reload
    if @board_image.update(status: "editing")
      render json: @board_image.api_view(current_user) and return
    else
      render json: { error: "Failed to create image edit" }, status: :unprocessable_content
    end
  end

  def create_image_variation
    # @board_image is loaded owner-scoped by set_owned_board_image.
    return unless check_credits!(feature_key: "image_variation", feature_name: "AI Image Variations")

    @image_variation = @board_image.create_image_variation!

    @board_image.reload
    if @image_variation
      render json: @board_image.api_view(current_user)
    else
      render json: { error: "Failed to create image variation" }, status: :unprocessable_content
    end
  end

  def upload_audio
    @board_image = owned_board_image
    default_file_name = @board_image.label.downcase.gsub(" ", "-").gsub("_", "-")
    default_file_name = !default_file_name.blank? ? default_file_name : "board-image-audio"
    random_number = Time.now.strftime("%m%d%y%H%M%S")
    extention = params[:audio_file]&.original_filename&.split(".")&.last || "mp3"
    default_file_name = "#{default_file_name}-custom-#{random_number}.#{extention}"
    @file_name = default_file_name
    @file_name = @file_name.downcase.gsub(" ", "-")
    @file_name = @file_name.downcase.gsub("_", "-")
    @file_name_to_save = @file_name.ends_with?(".#{extention}") ? @file_name : "#{@file_name}.#{extention}"
    @audio_file = @board_image.audio_files.attach(io: params[:audio_file], filename: @file_name_to_save)
    @board_image.reload
    @new_audio_file = @board_image.audio_files.last
    new_audio_file_url = @board_image.default_audio_url(@new_audio_file)
    # Determine the voice from the filename
    @board_image.data ||= {}
    @board_image.data["using_custom_audio"] = true
    if @board_image.update(audio_url: new_audio_file_url)
      @board_image.reload
      render json: @board_image.api_view(current_user)
    else
      render json: @board_image.errors, status: :unprocessable_content
    end
  end

  # POST /api/board_images/:id/attach_youtube_video
  # Persists only the parsed 11-char video id — the raw URL is discarded, so
  # client input can never reach an iframe src.
  def attach_youtube_video
    youtube_id = YoutubeUrlParser.video_id(params[:url])
    unless youtube_id
      render json: { error: "invalid_youtube_url" }, status: :unprocessable_content
      return
    end
    @board_image.set_youtube_video!(youtube_id)
    @board_image.board.broadcast_board_update!
    render json: @board_image.api_view(current_user)
  end

  # POST /api/board_images/:id/upload_video (multipart: video_file)
  #
  # Accepted types and the size cap both depend on whether ffmpeg is present
  # (see BoardImage.accepted_video_content_types): with it we take .mov/HEVC
  # at up to 100 MB and hand it to ProcessTileVideoJob to convert; without it
  # we stay on mp4/webm at 25 MB, since we'd have no way to make anything else
  # playable. Enforced here regardless of client checks.
  #
  # The 30s duration cap is enforced server-side by the job, not here — the
  # response goes out before ffmpeg runs so the editor isn't blocked on it.
  def upload_video
    file = params[:video_file]
    unless file.respond_to?(:content_type) && file.respond_to?(:size)
      render json: { error: "video_required" }, status: :unprocessable_content
      return
    end
    unless BoardImage.accepted_video_content_types.include?(file.content_type)
      render json: { error: "invalid_video_type" }, status: :unprocessable_content
      return
    end
    if file.size > BoardImage.max_video_upload_bytes
      render json: { error: "video_too_large" }, status: :unprocessable_content
      return
    end

    extension = VIDEO_UPLOAD_EXTENSIONS.fetch(file.content_type, "mp4")
    filename = "board-image-#{@board_image.id}-video-#{Time.now.strftime("%m%d%y%H%M%S")}.#{extension}"
    @board_image.video_clip.purge_later if @board_image.video_clip.attached?
    @board_image.video_clip.attach(io: file, filename: filename, content_type: file.content_type)
    @board_image.reload
    @board_image.set_uploaded_video!(@board_image.video_clip_url, file.content_type)
    @board_image.board.broadcast_board_update!
    # Enforces the duration cap and converts to web-safe mp4, then rebroadcasts
    # the board with the processed URL.
    ProcessTileVideoJob.perform_async(@board_image.id)
    render json: @board_image.api_view(current_user)
  end

  # POST /api/board_images/:id/clear_video
  def clear_video
    @board_image.clear_video!
    @board_image.board.broadcast_board_update!
    render json: @board_image.api_view(current_user)
  end

  def reset_audio
    @board_image = owned_board_image

    default_audio_url = @board_image.default_audio_url
    @board_image.data ||= {}
    @board_image.data["using_custom_audio"] = false
    if @board_image.update(audio_url: default_audio_url)
      render json: @board_image.api_view(current_user)
    else
      render json: @board_image.errors, status: :unprocessable_content
    end
  end

  # TODO - I don't think this is used but need to check
  def move
    @board_id = params[:board_id].to_i
    @image_id = params[:image_id].to_i

    @board = Board.find(@board_id)
    if @board.nil?
      render json: { error: "Board not found" }, status: :unprocessable_content
      return
    end

    @board_image = BoardImage.find_by(board_id: @board_id, image_id: @image_id)
    if @board_image.nil?
      render json: { error: "Board image not found" }, status: :unprocessable_content
      return
    end
    @new_image = Image.find(params[:new_image_id]&.to_i)
    @board_image.image = @new_image
    if @new_image.user_id != current_user.id
      render json: { error: "You do not have permission to move this image" }, status: :unprocessable_content
    end

    if @board_image.save
      render json: @board_image.api_view(current_user)
    else
      render json: @board_image.errors, status: :unprocessable_content
    end
  end

  # DELETE /board_images/1 or /board_images/1.json
  def destroy
    @board_image.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  private

  # Apply a bulk case transform to a display label.
  #   "upper"    -> "I WANT MORE"
  #   "lower"    -> "i want more"
  #   "sentence" -> "I want more" (first letter up, rest down)
  # Unknown modes return the text unchanged.
  def transform_label_case(text, mode)
    return text if text.blank?
    case mode.to_s
    when "upper"    then text.upcase
    when "lower"    then text.downcase
    when "sentence" then text.capitalize
    else text
    end
  end

  # Block edits to a board image when its board is read-only for this user
  # (a downgraded user over their board limit). Playing audio and viewing are
  # never gated — only content mutations. HTTP 403, not 402 (credits).
  def check_board_image_editable!
    board = board_for_editable_check
    return if board.nil?
    return if current_user&.board_editable?(board)

    render json: {
      error: "board_locked",
      message: "This board is read-only on your current plan. Upgrade, or make it your editable board, to make changes.",
      board_limit: current_user.board_limit,
      editable_board_id: current_user.effective_editable_board_id,
    }, status: :forbidden
  end

  def board_for_editable_check
    if params[:board_id].present?
      Board.find_by(id: params[:board_id])
    elsif @board_image
      @board_image.board
    elsif params[:id].present?
      BoardImage.find_by(id: params[:id])&.board
    end
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_board_image
    @board_image = BoardImage.includes(:audio_files_attachments).find_by(id: params[:id])
    if @board_image.nil?
      Rails.logger.error "BoardImage with ID #{params[:id]} not found."
      render json: { error: "Board image not found" }, status: :unprocessable_content
      return
    end
  end

  # Issue #26 (IDOR): load a board image the current user is allowed to mutate,
  # scoped to boards they own so a non-owner gets a 404 instead of being able to
  # edit/delete another user's tile. Admins may act cross-user.
  def set_owned_board_image
    @board_image = owned_board_image
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Board image not found" }, status: :not_found
  end

  # A board image owned by the current user (its board's user_id matches).
  # Raises ActiveRecord::RecordNotFound (=> 404) for a non-owner. Admins bypass.
  def owned_board_image(id = params[:id])
    return BoardImage.find(id) if current_user.admin?

    BoardImage.joins(:board).where(boards: { user_id: current_user.id }).find(id)
  end

  # Only allow a list of trusted parameters through.
  def board_image_params
    params.require(:board_image).permit(:board_id, :predictive_board_id,
                                        :image_id, :position, :voice, :bg_color, :border_color,
                                        :border_width, :border_radius,
                                        :text_color, :font_size, :border_color,
                                        :display_label,
                                        :label,
                                        :part_of_speech,
                                        :layout, :audio_url, :hidden, :src, :display_image_url)
  end
end
