class API::BoardImagesController < API::ApplicationController
  respond_to :json
  before_action :set_board_image, only: %i[ show ]
  before_action :set_owned_board_image, only: %i[ update destroy create_image_variation create_image_edit create_text_image set_current_audio attach_youtube_video upload_video clear_video ]
  before_action :check_board_image_editable!, only: %i[ save_layout set_current_audio update update_multiple remove_multiple create_image_edit create_image_variation create_text_image create_text_images upload_audio reset_audio move destroy attach_youtube_video upload_video clear_video ]

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

  # POST /api/board_images/:id/set_current_audio
  #
  # Takes an `audio_file_id` and resolves the URL server-side. The URL is
  # never taken from the client: this tile can be on a published board or a
  # MySpeak page, so an arbitrary `audio_url` would mean anyone's board could
  # be made to play a file from any host on the internet.
  def set_current_audio
    # @board_image is loaded owner-scoped by set_owned_board_image.
    attachment = resolve_audio_attachment(@board_image)
    unless attachment
      render json: { error: "audio_file_not_found" }, status: :unprocessable_content
      return
    end

    url = @board_image.default_audio_url(attachment)
    unless url
      render json: { error: "audio_file_not_found" }, status: :unprocessable_content
      return
    end

    voice = @board_image.voice_from_filename(attachment.blob.filename.to_s)
    # Selecting a synthesized voice has to clear the custom flag, or the tile
    # stays pinned out of the board's voice forever.
    if voice == BoardImage::CUSTOM_VOICE
      @board_image.set_custom_audio!(url)
    else
      @board_image.set_voice_audio!(url, voice)
    end
    @board_image.board.broadcast_board_update!
    render json: @board_image.api_view(current_user)
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
    # Read presence-first rather than truthiness-first like its neighbours: a
    # caller that omits hide_pictures entirely must leave the flag alone, not
    # silently clear it. (hide_images/hide_labels get away with the looser form
    # only because the bulk drawer is their sole caller and always sends both.)
    hide_pictures = if payload.key?(:hide_pictures)
        ActiveModel::Type::Boolean.new.cast(payload[:hide_pictures])
      end
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
      # "Hide pictures". A BLANK display_image_url is the app-wide marker for
      # "this tile has no picture" — every resolver chains with a bare `||` and
      # "" is truthy in Ruby, so the chain stops there rather than falling
      # through to the shared Image's art. Using the same marker rather than a
      # new flag is what makes this work in PDF exports, board covers, and
      # printables (Boards::BoardPdfLayoutNormalizer) on day one.
      # Must be "" and never nil, which would fall through and show the picture.
      unless hide_pictures.nil?
        if hide_pictures
          board_image.display_image_url = ""
        else
          board_image.unhide_picture!
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

  # POST /api/board_images/:id/create_text_image
  #
  # Renders the tile's picture from typed text instead of generating one. No
  # OpenAI call, so deliberately NO check_credits! — this is free, and that is
  # the headline of the feature. Don't add a credit gate here without changing
  # the button copy, which promises "no credits used".
  #
  # @board_image is loaded owner-scoped by set_owned_board_image.
  def create_text_image
    options = Images::TextTile::Options.from_params(params)
    unless options.valid?
      render json: { error: "invalid_text_tile_options" }, status: :unprocessable_content
      return
    end

    stored = @board_image.data&.dig("text_image")
    @board_image.data = (@board_image.data || {}).merge("text_image" => options.to_h)
    # Assigned both ways, not just when true: the form shows the tile's current
    # hide_label state, so unchecking the box has to put the label back.
    @board_image.data["hide_label"] = options.hide_label

    # Nothing about the picture changed and we still have it — skip the Chrome
    # fork. Tweaking a colour back and forth is cheap to do and expensive to
    # serve, so the no-op case must not cost a render.
    if unchanged_render?(@board_image, stored, options)
      @board_image.save!
      render json: @board_image.api_view(current_user)
      return
    end

    @board_image.status = "generating"
    @board_image.save!
    RenderTextTileJob.perform_async(@board_image.id, options.to_h)

    render json: @board_image.api_view(current_user)
  end

  # POST /api/board_images/create_text_images
  #
  # The bulk drawer's "Set text image": every selected tile gets ITS OWN label
  # rendered as its picture. There is deliberately no form on this path — one
  # shared string would paint every tile the same picture, and the whole point
  # of the bulk action is skipping the per-tile editor. So nothing here may
  # depend on a preview to come out right, which is why the two colours are
  # derived rather than defaulted:
  #
  #   * the background is TRANSPARENT, not the tile's colour. A baked-in colour
  #     goes stale the moment the tile is recoloured, while a transparent PNG
  #     keeps following it — the same reason generate_placeholder_image is
  #     transparent, so screen and print keep agreeing.
  #   * the text colour is derived from the tile's own background. Options'
  #     near-black default is unreadable on a dark tile, and with no preview
  #     nobody would see it happen.
  #
  # Free, like its single-tile sibling create_text_image — deliberately NO
  # check_credits!. Ownership comes from scoping to @board.board_images plus
  # check_board_image_editable!, as on update_multiple.
  def create_text_images
    # Rack encodes an empty array as a single empty element, so a selection of
    # nothing arrives as [""] rather than [] — reject blanks before the guard
    # or it reads as a real selection and answers 200 having done nothing.
    board_image_ids = Array(params[:board_image_ids]).reject(&:blank?)
    @board = Board.includes(:board_images).find_by(id: params[:board_id])
    if @board.nil?
      render json: { error: "Board not found" }, status: :unprocessable_content
      return
    end
    if board_image_ids.empty?
      render json: { error: "No board image IDs provided" }, status: :unprocessable_content
      return
    end

    queued = 0
    unlabeled = 0
    unchanged = 0
    # One job for the whole selection, not one per tile — see RenderTextTilesJob
    # for why (queue fairness, plus in-batch dedupe of identical renders).
    entries = []

    @board.board_images.where(id: board_image_ids).each do |board_image|
      options = default_text_tile_options_for(board_image)

      # A picture-only tile has no text to render. Skip it rather than failing
      # the batch: one of them in a select-all must not cost the other twenty-nine.
      unless options.valid?
        unlabeled += 1
        next
      end

      stored = board_image.data&.dig("text_image")
      board_image.data = (board_image.data || {}).merge("text_image" => options.to_h)
      board_image.data["hide_label"] = options.hide_label

      # Already showing exactly this render — don't pay for another Chrome fork.
      if unchanged_render?(board_image, stored, options)
        board_image.save!
        unchanged += 1
        next
      end

      board_image.status = "generating"
      board_image.save!
      entries << [board_image.id, options.to_h]
      queued += 1
    end

    RenderTextTilesJob.perform_async(entries) if entries.any?

    @board.broadcast_board_update!
    render json: {
      board: @board.api_view_with_predictive_images(current_user, true),
      queued: queued,
      unlabeled: unlabeled,
      unchanged: unchanged,
    }
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

  # POST /api/board_images/:id/upload_audio (multipart: audio_file)
  #
  # Accepted types depend on whether ffmpeg is present
  # (BoardImage.accepted_audio_content_types): with it we take the browser's
  # webm/ogg recording and hand it to ProcessCustomAudioJob to convert; without
  # it we stay on formats every device already plays, since we'd have no way to
  # make anything else audible on an iPad. Enforced here regardless of what the
  # client checked.
  #
  # The 60s cap is enforced by the job, not here — the response goes out before
  # ffmpeg runs so the editor isn't blocked on it.
  def upload_audio
    @board_image = owned_board_image
    file = params[:audio_file]

    unless file.respond_to?(:content_type) && file.respond_to?(:size)
      render json: { error: "audio_required" }, status: :unprocessable_content
      return
    end
    unless BoardImage.accepted_audio_content_types.include?(file.content_type)
      render json: { error: "invalid_audio_type" }, status: :unprocessable_content
      return
    end
    if file.size > BoardImage::MAX_AUDIO_BYTES
      render json: { error: "audio_too_large" }, status: :unprocessable_content
      return
    end

    @board_image.audio_files.attach(
      io: file, filename: custom_audio_filename(@board_image, file), content_type: file.content_type
    )
    @board_image.reload

    # The row we just created — `find_custom_audio_file` returns the *first*
    # custom clip, which is the wrong one once a tile has been re-recorded.
    attachment = @board_image.audio_files_attachments.order(:id).last
    unless attachment
      render json: { error: "audio_upload_failed" }, status: :unprocessable_content
      return
    end

    @board_image.set_custom_audio!(@board_image.default_audio_url(attachment))
    ProcessCustomAudioJob.perform_async(@board_image.id, attachment.id)
    @board_image.board.broadcast_board_update!
    render json: @board_image.api_view(current_user)
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
    range = BoardImage.parse_video_range(params[:start_seconds], params[:end_seconds])
    unless range
      render json: { error: "invalid_video_range" }, status: :unprocessable_content
      return
    end
    @board_image.set_youtube_video!(youtube_id, range)
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

  # POST /api/board_images/:id/reset_audio — back to the board's voice.
  #
  # Clears the custom flag first so the URL resolves against voice files
  # rather than the recording being reset away from. When no file exists for
  # that voice yet, the tile keeps its current URL and SaveAudioJob fills it
  # in — never leave a tile with no audio_url at all.
  def reset_audio
    @board_image = owned_board_image
    voice = @board_image.board.voice.presence || @board_image.voice

    @board_image.data = (@board_image.data || {}).merge("using_custom_audio" => false)
    @board_image.save!

    url = @board_image.audio_url_for_voice(voice, @board_image.language)
    if url.present?
      @board_image.set_voice_audio!(url, voice)
    else
      @board_image.set_voice_audio!(@board_image.audio_url, voice)
      # set_voice_audio! has just pinned the tile to `voice`, so the enqueue
      # reads the same value off the record.
      @board_image.enqueue_voice_audio_job
    end

    @board_image.board.broadcast_board_update!
    render json: @board_image.api_view(current_user)
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

  # The bulk path's option set: defaults, seeded from the tile itself. See
  # create_text_images for why the two colours are derived rather than left to
  # Options' defaults.
  def default_text_tile_options_for(board_image)
    Images::TextTile::Options.new(
      text: board_image.display_label.presence || board_image.label,
      bg_color: Images::TextTile::Options::TRANSPARENT,
      text_color: ColorHelper.text_hex_for(board_image.bg_hex),
      hide_label: true,
    )
  end

  # Would this text-tile request paint exactly what the tile already shows?
  # Compares only the pixel-affecting options (Options#render_digest drops
  # hide_label), and insists the doc it produced is still there and still the
  # picture on screen — a stale config with a deleted doc must re-render.
  def unchanged_render?(board_image, stored, options)
    return false if stored.blank?
    return false if board_image.display_image_url.blank?

    doc_id = stored["doc_id"]
    return false if doc_id.blank?
    return false unless Doc.exists?(id: doc_id)

    Images::TextTile::Options.from_params(stored.symbolize_keys).render_digest == options.render_digest
  end

  # "<label>-custom-<timestamp>.<ext>" — the "custom" marker is what flags the
  # clip as user-supplied everywhere else (has_custom_audio?,
  # voice_from_filename). A random suffix rides along because the timestamp
  # alone collides when two clips land in the same second.
  def custom_audio_filename(board_image, file)
    base = board_image.label.to_s.downcase.gsub(/[\s_]+/, "-").gsub(/[^a-z0-9\-]/, "")
    base = "board-image-audio" if base.blank?
    ext = File.extname(file.original_filename.to_s).delete(".").downcase
    ext = "mp3" if ext.blank?
    "#{base}-custom-#{Time.now.strftime("%m%d%y%H%M%S")}-#{SecureRandom.hex(3)}.#{ext}"
  end

  # The attachment a set_current_audio call is asking for. Looks in the tile's
  # own audio files and the shared Image's, which is the same set the API
  # returns in `audio_files`.
  def resolve_audio_attachment(board_image)
    candidates = board_image.audio_owner_records.flat_map { |owner| owner.audio_files_attachments.to_a }

    audio_file_id = params[:audio_file_id] || params.dig(:board_image, :audio_file_id)
    return candidates.find { |a| a.id.to_s == audio_file_id.to_s } if audio_file_id.present?

    # Shipped native builds still send the URL. Honour it only when it matches
    # a file that actually belongs to this tile.
    legacy_url = params.dig(:board_image, :audio_url)
    return nil if legacy_url.blank?
    candidates.find { |a| board_image.default_audio_url(a) == legacy_url }
  end

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
