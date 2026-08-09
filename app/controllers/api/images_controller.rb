class API::ImagesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[generate_audio public_audio]

  ALLOWED_SORT_FIELDS = %w[label created_at updated_at id].freeze
  ALLOWED_SORT_ORDERS = %w[asc desc].freeze

  def index
    @current_user = current_user
    sort_field = ALLOWED_SORT_FIELDS.include?(params[:sort_field]) ? params[:sort_field] : "label"
    sort_order = ALLOWED_SORT_ORDERS.include?(params[:sort_order]&.downcase) ? params[:sort_order].downcase : "asc"
    if params[:user_only] == "1"
      @images = Image.searchable.with_artifacts.where(user_id: @current_user.id)
    else
      @images = Image.searchable.with_artifacts.where(user_id: [nil, User::DEFAULT_ADMIN_ID])
    end

    if params[:query].present?
      @images = @images.by_label(params[:query]).order(Arel.sql("#{sort_field} #{sort_order}")).page params[:page]
    else
      @images = @images.order(Arel.sql("#{sort_field} #{sort_order}")).page params[:page]
    end

    render json: @images.map { |image| image.api_view(@current_user) }
  end

  def user_images
    render json: { status: "error", message: "User images endpoint is deprecated.  Please use the images endpoint with the user_only parameter." }
  end

  def show
    @current_user = current_user

    id = params[:id]

    @image = Image.with_artifacts.find(id)
    @board = Board.with_artifacts.find_by(id: params[:board_id]) if params[:board_id].present?
    @board_image = BoardImage.with_artifacts.find_by(image_id: @image.id, board_id: @board.id) if @board

    # @image_with_display_doc = @image.with_display_doc(@current_user, @board, @board_image)

    render json: { image: @image.with_display_doc(@current_user), board: @board&.api_view(@current_user), board_image: @board_image&.api_view(@current_user) }
  end

  def all_board_images
    @current_user = current_user
    @image = Image.with_artifacts.find(params[:id])
    if @current_user.admin?
      @board_images = @image.board_images.includes(:board).where(boards: { user_id: [@current_user.id, nil] }).order(created_at: :desc)
    else
      @board_images = @image.board_images.includes(:board).where(boards: { user_id: @current_user.id }).order(created_at: :desc)
    end

    render json: { board_images: @board_images.map { |bi| bi.api_view(@current_user) } }
  end

  def user_docs
    @current_user = current_user
    label = params[:label]
    @images = Image.with_artifacts.by_label(label).where(user_id: @current_user.id)
    if @current_user.admin?
      @docs = UserDoc.where(image_id: @images.pluck(:id)).includes(:doc, :image).order(created_at: :desc).page params[:page]
    else
      @docs = UserDoc.where(image_id: @images.pluck(:id)).for_user(@current_user).includes(:doc, :image).order(created_at: :desc).page params[:page]

      # @docs = @current_user.docs.where(documentable_type: "Image").order(created_at: :desc).page params[:page]
    end

    render json: { docs: @docs.map(&:api_view) }
  end

  def crop
    @current_user = current_user

    label = image_params[:label]
    image_id = params["image"]["id"]
    @image = accessible_image(image_id) if image_id.present?
    @image = Image.by_label(label).find_by(user_id: @current_user.id) unless @image
    @image = Image.create(label: label, user_id: @current_user.id) unless @image
    @doc = attach_doc_to_image(@image, @current_user, params[:cropped_image], params[:file_extension])

    if @doc.save
      @image.update(status: "finished")
      saved_image_url = @doc.tile_url
      if check_update_board_image(saved_image_url)
        render json: { image_url: saved_image_url, id: @image.id, doc_id: @doc.id, board_id: @board&.id, board_image_id: @board_image&.id } and return
      end
      @image.reload
      render json: @image.api_view(@current_user), status: :created
    else
      render json: @image.errors, status: :unprocessable_content
    end
  end

  # Google Search API
  def save_temp_doc
    @current_user = current_user
    if params[:imageId].present?
      @existing_image = accessible_image(params[:imageId])
    end

    label = params[:query]
    @existing_image = Image.by_label(label).find_by(user_id: @current_user.id) unless @existing_image
    @image = nil
    if @existing_image
      @image = @existing_image
    else
      @image = Image.create(user: @current_user, label: label, private: true, image_prompt: params[:title], image_type: "User")
    end
    saved_image_doc = @image.save_from_url(params[:imageUrl], params[:snippet], params[:title], "image/webp", @current_user.id)
    saved_image_url = saved_image_doc.tile_url
    @image.update_all_boards_image_belongs_to(saved_image_url, false, @current_user.id)
    # UpdateBoardImagesJob.perform_async(@image.id, saved_image_url)
    @doc = @image.docs.last
    user_docs_to_delete = @current_user.user_docs.where(image_id: @image.id)
    user_docs_to_delete.destroy_all
    user_doc = UserDoc.create!(user_id: current_user.id, doc_id: @doc.id, image_id: @doc.documentable_id)
    did_update = @doc.update(current: true)

    if @doc.save
      if check_update_board_image(saved_image_url)
        render json: { image_url: saved_image_url, id: @image.id, doc_id: @doc.id }
      else
        render json: { image_url: saved_image_url, id: @image.id, doc_id: @doc.id }
      end
    else
      render json: @image.errors, status: :unprocessable_content
    end
  end

  def merge
    @current_user = current_user
    unless @current_user.admin?
      render json: { status: "error", message: "You are not authorized to merge images." }, status: :forbidden
      return
    end
    # Admin-only (gated above): merging is a cross-user library operation, so the
    # lookup is intentionally unscoped. Non-admins never reach here (issue #26).
    @image = Image.find(params[:id])
    @images_to_merge = Image.where(id: params[:merge_image_ids])
    if @images_to_merge.empty?
      render json: { status: "error", message: "No images found to merge." }, status: :not_found
      return
    end
    @images_to_merge.each do |image_to_merge|
      image_to_merge.docs.each do |doc|
        doc.documentable = @image
        doc.user = @current_user
        result = doc.save!
      end
      board_images = BoardImage.where(image_id: image_to_merge.id)
      board_images.each do |board_image|
        board_image.update(image_id: @image.id)
        board_image.save_defaults
      end
      image_to_merge.update(status: "marked_for_deletion")
    end

    DeleteImageJob.perform_in(1.minute, @images_to_merge.map(&:id))
    @image.reload
    render json: { image: @image.with_display_doc(@current_user) }
  end

  def clone
    @current_user = current_user
    @image = Image.with_artifacts.find(params[:id])
    label_to_set = params[:new_name] || @image.label
    user_id = @current_user.id
    make_dynamic = params[:make_dynamic] == "1"
    word_list = params[:word_list] ? params[:word_list].compact : nil
    @image_clone = @image.clone_with_current_display_doc(user_id, label_to_set, make_dynamic, word_list)
    voice = params[:voice] || "polly:kevin"
    text = params[:text] || @image_clone.label
    @original_audio_files = @image.audio_files
    @original_audio_files.each do |audio_file|
      begin
        original_file = audio_file.dup
        @audio_file = @image_clone.audio_files.attach(io: StringIO.new(original_file.download), filename: audio_file.blob.filename)
      rescue StandardError => e
        puts "Error copying audio files #{original_file.filename}: #{e.message}"
      end
    end

    @image_with_display_doc = @image_clone.with_display_doc(@current_user)
    render json: @image_with_display_doc
  end

  def predictive_images
    @current_user = current_user
    @image = Image.includes(:docs, :predictive_boards).find(params[:id])
    if !@image.user_id || (current_user.id != @image.user_id)
      puts "User not authorized to view image.  Sending next images."
    else
      @board = @image.predictive_board
    end

    if !@board
      @board = Board.predictive_default(@current_user)
    end

    @board_with_images = @board.api_view_with_predictive_images(@current_user)

    render json: @board_with_images
  end

  def upload_audio
    @image = current_user.images.find(params[:id])
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

    base = (params[:file_name].presence || File.basename(file.original_filename.to_s, ".*")).downcase.gsub(/[\s_]+/, "-")
    ext = File.extname(file.original_filename.to_s).delete(".").downcase.presence || "mp3"
    # The extension has to survive: it's what Active Storage infers the
    # content type from, and what "custom" marks the clip with for
    # voice_from_filename.
    @file_name_to_save = "#{base}-custom-#{Time.now.strftime("%m%d%y%H%M%S")}-#{SecureRandom.hex(3)}.#{ext}"

    @image.audio_files.attach(io: file, filename: @file_name_to_save, content_type: file.content_type)
    @image.reload
    # The row just created. `attach` returns the association proxy, whose
    # `.first` is the OLDEST attachment and whose `.blob` raises.
    @audio_file = @image.audio_files_attachments.order(:id).last
    new_audio_file_url = @image.default_audio_url(@audio_file)

    if @image.update(audio_url: new_audio_file_url, voice: @image.voice_from_filename(@file_name_to_save), use_custom_audio: true)
      @image_with_display_doc = @image.with_display_doc(current_user)
      render json: { status: "ok", image: @image_with_display_doc, audio_file: @audio_file.id, audio_url: new_audio_file_url, filename: @file_name_to_save, voice: @image.voice_from_filename(@file_name_to_save) }
    else
      render json: @image.errors, status: :unprocessable_content
    end
  end

  def create_audio
    if params[:board_image_id].present?
      # Owner-scoped: synthesizing audio rewrites the tile's voice/audio_url
      # and spends on the TTS provider, so a non-owner gets a 404 rather than
      # the ability to do either on someone else's board. Issue #26 (IDOR).
      @board_image = owned_board_image_for_audio(params[:board_image_id])
      unless @board_image
        render json: { error: "Board image not found" }, status: :not_found
        return
      end
      @board = @board_image.board
      @image = @board_image.image
      voice = VoiceService.normalize_voice(params[:voice] || @board_image.voice || "alloy")
      language = params[:language] || "en"
      label = params[:label] || @board_image.label

      @board_image.create_audio_from_text(label, voice, language, params[:instructions])

      @board_image.reload
      # Synthesizing a voice takes the tile off custom audio — otherwise the
      # flag keeps it pinned out of the board's voice while playing TTS.
      @board_image.set_voice_audio!(@board_image.audio_url, voice) if @board_image.audio_url.present?
      @board_image.board&.broadcast_board_update!
      @image_with_display_doc = @image.with_display_doc(current_user, @board, @board_image)
      # render json: { image: @image_with_display_doc, board: @board&.api_view(@current_user), board_image: @board_image&.api_view(@current_user) } and return
      render json: { audio_files: @board_image.audio_files_for_api, image: @image_with_display_doc, board: @board&.api_view(@current_user), board_image: @board_image&.api_view(@current_user) } and return
    else
      @board = Board.find_by(id: params[:board_id]) if params[:board_id].present?
      @image = Image.with_artifacts.find(params[:id])
    end
    @image = Image.with_artifacts.find(params[:id])
    text = params[:text] || @image.label
    language = params[:language] || "en"
    if text != @image.label
      @image.update(label: text)
    end

    @audio_file = @image.create_audio_from_text(text, voice, language, params[:instructions])
    @image.reload
    @image_with_display_doc = @image.with_display_doc(current_user)
    render json: @image_with_display_doc
  end

  def generate_audio
    input_text = params[:text].to_s

    begin
      user_speed = current_user&.settings&.dig("voice", "speed")
      user_speed = user_speed.blank? ? 1.0 : user_speed

      speed = params[:speed].presence || user_speed
      valid_speeds = 0.25..4.0
      speed = valid_speeds.include?(speed.to_f) ? speed.to_f : 1.0

      voice_value = params[:voice].presence || "polly:kevin"

      audio_io = VoiceService.synthesize_speech(
        text: input_text,
        voice_value: voice_value,
        # (Optional later) speed: speed
      )

      raise "No audio returned" if audio_io.nil?

      audio_io.rewind if audio_io.respond_to?(:rewind)
      audio_data = audio_io.read if audio_io.respond_to?(:read)
      unless audio_data
        audio_data = audio_io.is_a?(String) ? audio_io : nil
      end
      safe_voice = voice_value.tr(":", "_") # avoid colon in filename
      filename = "#{input_text.parameterize}_#{safe_voice}_#{speed}.mp3"

      send_data audio_data,
        type: "audio/mpeg",
        disposition: "attachment",
        filename: filename
    rescue StandardError => e
      Rails.logger.error("Error generating audio: #{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}")
      render json: { error: "Failed to generate audio" }, status: :internal_server_error
    end
  end

  def public_audio
    # Intentionally public + unscoped (skip_before_action :authenticate_token!):
    # this is an AAC audio-playback path that must work for unauthenticated
    # viewers of a shared page, so it is left unscoped by design (issue #26).
    @image = Image.find(params[:id])
    # voice = params[:voice] || @image.voice || "alloy"
    voice = @image.voice || "alloy"
    language_to_use = params[:language] || "en"
    audio_url = @image.default_audio_url
    if audio_url.blank?
      render json: { status: "error", message: "Audio file URL is blank." }, status: :not_found
      return
    end
    begin
      render json: { status: "ok", audio_url: audio_url, voice: voice, language: language_to_use, label: @image.label }

      # audio_file = URI.open(audio_url)
      # send_data audio_file, type: "audio/mpeg", disposition: "inline", filename: "#{@image.label.parameterize}_#{voice}_#{language_to_use}.mp3"
    rescue OpenURI::HTTPError => e
      Rails.logger.error("Error fetching audio file: #{e.message}")
      render json: { status: "error", message: "Failed to fetch audio file." }, status: :internal_server_error
    rescue StandardError => e
      Rails.logger.error("Error sending audio data: #{e.message}")
      render json: { status: "error", message: "Failed to send audio data." }, status: :internal_server_error
    end
  end

  def create
    @current_user = current_user

    find_first = image_params[:find_first] == "1"
    duplicate_image = image_params[:duplicate] == "1"

    label = image_params[:label]
    @existing_image = Image.by_label(label).find_by(user_id: @current_user.id)
    @image = nil
    if @existing_image && find_first && !duplicate_image
      @image = @existing_image
    else
      @image = Image.create(user: @current_user, label: label, private: true, image_prompt: image_params[:image_prompt], image_type: "User")
    end
    if image_params[:docs]
      doc = @image.docs.new(image_params[:docs])
      doc.user = @current_user
      doc.processed = true
      doc.source_type = Doc::SOURCE_TYPE_USER
      if doc.save
        @image_with_display_doc = @image.attributes.merge({ display_doc: doc.attributes, src: doc.tile_url })
        render json: @image.with_display_doc(@current_user), status: :created
      else
        render json: @image.errors, status: :unprocessable_content
      end
    else
      if @image.save
        display_doc = @image.display_doc(@current_user)
        @image.start_generate_image_job(0, @current_user.id, image_params[:image_prompt], params[:board_id]) unless display_doc
        @image_with_display_doc = @image.with_display_doc(@current_user)
        render json: @image_with_display_doc, status: :created
      else
        render json: @image.errors, status: :unprocessable_content
      end
    end
  end

  def add_doc
    @image = accessible_image
    @doc = @image.docs.new(image_params[:docs])
    @doc.user = current_user
    @doc.processed = true
    @doc.source_type = Doc::SOURCE_TYPE_USER
    if @doc.save
      render json: @image, status: :created
    else
      render json: @image.errors, status: :unprocessable_content
    end
  end

  def set_next_words
    @image = Image.includes(predictive_board: :current_word_list).find(params[:id])
    if params[:next_words].present?
      @image.next_words = params[:next_words]&.compact_blank
      @image.save
      if @image.predictive_board&.id === Board.predictive_default.id
      else
        @board = @image.predictive_board
        if @board
          new_words = @image.next_words.keep_if { |word| !@board.current_word_list.include?(word) }
          @board.find_or_create_images_from_word_list(new_words)
        end
      end
    else
      @image.set_next_words!
      # CreateAllAudioJob.perform_async(@image.id)
    end

    @image.create_words_from_next_words
    # if @image.predictive_board&.id === Board.predictive_default.id
    #   CreatePredictiveBoardJob.perform_async(@image.id, User::DEFAULT_ADMIN_ID)
    # end
    render json: @image.api_view(current_user)
  end

  def create_predictive_board
    @image = accessible_image
    board_id = params[:board_id]
    @board = Board.with_artifacts.find_by(id: board_id) if board_id.present?
    unless @board.nil?
      @board_image = @board.board_images.find_by(image_id: @image.id)
      if @board_image.nil?
        @board_image = @board.add_image(@image.id)
      end
    end

    user_id = current_user.id
    word_list = params[:word_list] ? params[:word_list].compact : nil
    board_settings = params[:board_settings] || {}

    board_settings[:board_id] = params[:board_id] if params[:board_id].present?
    board_settings[:voice] = @board.voice if @board && @board.voice.present?
    new_board_name = params[:name] || "#{@image.label.capitalize}"
    column_data = {}
    column_data[:large_screen_columns] = params[:large_screen_columns] if params[:large_screen_columns].present?
    column_data[:medium_screen_columns] = params[:medium_screen_columns] if params[:medium_screen_columns].present?
    column_data[:small_screen_columns] = params[:small_screen_columns] if params[:small_screen_columns].present?
    predictive_board = @image.create_predictive_board(user_id, word_list, new_board_name, board_settings, column_data)

    predictive_board.display_image_url = @board_image.display_image_url if @board_image
    predictive_board.save!

    unless @board_image && predictive_board
      render json: { status: "error", message: "Could not create predictive board." }
      return
    end
    @board_image.data["mute_name"] = true
    if @board_image.update(predictive_board_id: predictive_board.id)
      attach_to_builder_set(@board, predictive_board)
      render json: { status: "ok", message: "Creating predictive board for image.", board: predictive_board }
    else
      render json: { status: "error", message: "Could not create predictive board." }
    end
  end

  SYMBOL_LIMMIT = ENV["SYMBOL_LIMIT"] || 1
  ADMIN_SYMBOL_LIMIT = ENV["ADMIN_SYMBOL_LIMIT"] || 10

  def create_symbol
    @image = accessible_image
    if @image.open_symbol_status == "disabled"
      render json: { status: "error", message: "Symbol generation is disabled for this image." }, status: :unprocessable_content
      return
    end
    limit = current_user.admin? ? ADMIN_SYMBOL_LIMIT : SYMBOL_LIMMIT
    result = @image.generate_matching_symbol(limit)
    # @image.update(status: "finished") unless @image.finished?
    # render json: { status: "ok", message: "Creating #{limit} symbols for image.", image: @image }
    @image.reload
    @board = Board.find_by(id: params[:board_id]) if params[:board_id]
    @board_image = @board.board_images.find_by(image_id: @image.id) if @board
    @current_user = current_user
    @image_with_display_doc = @image.with_display_doc(@current_user, @board, @board_image)
    if result[:total] == 0
      @image.update(open_symbol_status: "disabled")
      render json: { status: "error", message: "No symbols created for image.", image: @image_with_display_doc, board: @board&.api_view(@current_user), board_image: @board_image&.api_view(@current_user) }, status: :unprocessable_content
      return
    end
    render json: { image: @image_with_display_doc, board: @board&.api_view(@current_user), board_image: @board_image&.api_view(@current_user), status: "ok", created: result[:created], skipped: result[:skipped], total: result[:total] }
  end

  def new
    @image = Image.new
  end

  def generate
    @current_user = current_user
    label = image_params[:label].present? ? image_params[:label] : image_params[:image_prompt]
    image_prompt = image_params[:image_prompt]
    stripped_prompt = image_prompt.gsub("[[REPLACE_LABEL]]", "").strip

    if !params[:id].blank?
      @image = accessible_image
    else
      @image = Image.find_or_create_by(label: label, user_id: @current_user.id, private: false, image_prompt: stripped_prompt, image_type: "Generated")
    end

    # image_generation is free for first-time fills (no `check_credits!` call
    # below in that case) — so on THIS route email verification is the only
    # gate standing between an unverified account and free OpenAI spend. Note
    # the communicator-side twin, API::Account::ImagesController#run_generate,
    # has no token/credit/verification guard at all; it is only weakly
    # reachable (a Free user's self-created communicator is forced to SANDBOX,
    # which has no passcode and so no child token). Tracked separately.
    # Checked after the
    # accessible_image lookup so a non-owner's private image still 404s before
    # this, same precedence as check_board_editable!'s resource-then-permission
    # ordering.
    return unless require_verified_email!

    # Building the library is free: only charge when the image already has a
    # displayable picture for this user (i.e. they're replacing/customizing it).
    # First-time generation for an empty tile generates the image but isn't billed.
    if @image.display_image_url(@current_user).present?
      return unless check_credits!(feature_key: "image_generation", feature_name: "AI Image Generation")
    end

    # The prompt the user typed is the *subject*; Images::PromptBuilder always
    # wraps it in the house style envelope. There used to be a length heuristic
    # here that let any prompt longer than the label escape styling entirely.
    # `[[REPLACE_LABEL]]` remains the admin escape hatch for raw prompts.
    raw_prompt = current_user.admin? && image_prompt.to_s.include?("[[REPLACE_LABEL]]")
    @image.image_prompt = stripped_prompt.presence
    @image.status = "generating"
    @image.save!

    board_id = params[:board_id]
    screen_size = params[:screen_size] || "lg"
    transparent_background = params[:transparent_background] != "false"
    @board_image = BoardImage.find_by(board_id: board_id, image_id: @image.id) if board_id
    options = {
      "image_prompt" => raw_prompt ? image_prompt : stripped_prompt.presence,
      "board_id" => board_id,
      "screen_size" => screen_size,
      "transparent_bg" => transparent_background,
      "style" => params[:style],
      "raw_prompt" => raw_prompt,
    }
    GenerateImageJob.perform_async(@image.id, @current_user.id, options)
    if @board_image
      @board_image.update(status: "generating")
      return render json: { board_image: @board_image.api_view(@current_user) }
    end
    @image_docs = @image.docs.for_user(@current_user).order(created_at: :desc)

    @image_with_display_doc = {
      id: @image.id,
      label: @image.label.upcase,
      image_prompt: @image.image_prompt,
      bg_color: @image.bg_class,
      image_type: @image.image_type,
      text_color: @image.text_color,
      generating_status: "generating",
      status: "generating",
      display_doc: {
        id: @current_doc&.id,
        label: @image&.display_label,
        user_id: @current_doc&.user_id,
        src: @current_doc&.image&.url,
        is_current: true,
      },
      private: @image.private,
      src: @image.display_image_url(@current_user),
      audio: @image.default_audio_url,
      docs: @image_docs.map do |doc|
        {
          id: doc.id,
          label: @image.display_label,
          user_id: doc.user_id,
          src: doc.image.url,
          is_current: doc.id == @current_doc_id,
        }
      end,

    }
    render json: @image_with_display_doc
  end

  def prompt_suggestion
    @current_user = current_user
    @image = accessible_image
    prompt = @image.get_image_prompt_suggestion
    scrubbed_prompt = prompt.gsub('"', "")
    render json: { prompt: scrubbed_prompt }
  end

  def find_or_create
    @current_user = current_user

    generate_image = params["generate_image"] == "1"
    duplicate_image = params["duplicate"] == "1"
    label = image_params["label"]

    is_private = image_params["private"] || false
    @image = Image.by_label(label).find_by(user_id: @current_user.id)
    @image = Image.public_img.by_label(label).first unless @image
    @found_image = @image
    @image = Image.create(label: label, private: is_private, user_id: @current_user.id, image_prompt: image_params[:image_prompt], image_type: "User") unless @image || (@found_image && duplicate_image)

    @board = Board.find_by(id: image_params[:board_id]) unless image_params[:board_id].blank?
    if @board.nil? && duplicate_image && !generate_image && !@image.blank?
      return render json: @image.api_view(@current_user), status: :ok
    end

    if @board&.predefined && (@board&.user_id != @current_user.id)
      return render json: @image.api_view(@current_user), status: :ok unless @current_user.admin?
    end
    new_board_image = @board.add_image(@image.id) if @board

    if @found_image
      notice = "Image found!"
      @found_image.update(status: "finished") unless @found_image.finished?
      run_generate if generate_image
    else
      if @current_user.tokens > 0 && generate_image
        notice = "Generating image..."
        run_generate
      elsif !generate_image
        notice = "Image created! Remember you can always upload your own image or generate one later."
      else
        notice = "You don't have enough tokens to generate an image."
      end
    end

    if new_board_image
      render json: new_board_image.api_view
    else
      render json: @image.api_view(@current_user), notice: notice
    end
  end

  def find_by_label
    @current_user = current_user
    label = params[:label]
    @image = Image.by_label(label).find_by(user_id: @current_user.id)
    @image = Image.public_img.by_label(label).first unless @image
    if @image
      @image_with_display_doc = @image.with_display_doc(@current_user)
      render json: @image_with_display_doc
    else
      render json: { status: "error", message: "Image not found." }
    end
  end

  def update
    @image = current_user.images.find(params[:id])

    if @image.update(image_params)
      render json: @image.with_display_doc(current_user)
    else
      render json: @image.errors, status: :unprocessable_content
    end
  end

  def clear_current
    @image = accessible_image
    if @image.nil?
      render json: { status: "error", message: "Image not found." }
    else
      @user = @image.user
      current_user.user_docs.where(image_id: @image.id).destroy_all
      @board = Board.find_by(id: params[:board_id]) if params[:board_id].present?
      if params[:update_all]
        @image.board_images.each do |board_image|
          board_image.update(display_image_url: nil)
        end
      else
        @board_image = BoardImage.where(image_id: @image.id, board_id: @board.id).first
        @board_image.update!(display_image_url: nil) if @board_image
      end

      @image_docs = @image.docs.for_user(current_user).order(created_at: :desc)
      @image_docs.update_all(current: false)

      @image_with_display_doc = @image.with_display_doc(current_user)
      @image_with_display_doc[:src] = nil
      @current_user = current_user
      render json: { image: @image_with_display_doc, board: @board&.api_view(@current_user), board_image: @board_image&.api_view(@current_user) }
    end
  end

  def search
    @current_user = current_user
    if params[:user_images_only] == "1"
      @images = Image.searchable_images_for(@current_user, true).order(label: :asc).page params[:page]
    else
      @images = Image.searchable_images_for(@current_user).order(label: :asc).page params[:page]
    end

    if params[:query].present?
      @images = @images.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page params[:page]
    else
      @images = @images.order(label: :asc).page params[:page]
    end
    @images_with_display_doc = @images.map do |image|
      {
        id: image.id,
        label: image.display_label,
        image_prompt: image.image_prompt,
        src: image.display_image_url(@current_user),
        audio: image.default_audio_url,
      }
    end
  end

  def predictive
    if params["ids"].present?
      @images = Image.with_artifacts.where(id: params["ids"])
    end
    @images = @images.order(label: :asc).page params[:page]
    @images_with_display_doc = @images.map do |image|
      {
        id: image.id,
        label: image.display_label,
        image_prompt: image.image_prompt,
        src: image.display_image_url(current_user),
        audio: image.default_audio_url,
      }
    end
    render json: @images_with_display_doc
  end

  def hide_doc
    @image = accessible_image
    @doc = @image.docs.find(params[:doc_id])
    unless (@doc.user_id == current_user.id) || current_user.admin?
      render json: { status: "error", message: "You are not authorized to delete this document." }
      return
    end
    begin
      doc_url = @doc.tile_url
      if @image.src_url == doc_url
        @image.update(src_url: nil)
      end
      @image.docs.delete(@doc)
      @image.docs.reload
      if params[:hard_delete]
        Rails.logger.info("Hard deleting document: #{@doc.id} for image: #{@image.id}")
        @doc.destroy
      else
        @doc.hide!
      end
      @image.reload
      @image_with_display_doc = @image.with_display_doc(current_user)
      render json: { image: @image_with_display_doc, status: "ok" } and return
    rescue FrozenError => e
      render json: { image: @image_with_display_doc, status: "ok" }

      # render json: { image: @image_with_display_doc, status: "ok" } and return
      # Ignore frozen error
      # render json: { status: "ok", message: e.message } and return
    rescue StandardError => e
      render json: { status: "error", message: e.message } and return
    end
  end

  def destroy
    @image = current_user.images.find(params[:id])
    @image.destroy
    render json: { status: "ok" }
  end

  def sample_voices
    @voices = Image.sample_audio_files
    render json: @voices
  end

  def destroy_audio
    # Owner-only: purging audio is destructive, so scope to the caller's own
    # images (matches upload_audio / set_current_audio). Issue #26 (IDOR).
    @image = current_user.images.find(params[:id])
    unless params[:audio_file_id].present?
      render json: { status: "error", message: "No audio file id provided." }
      return
    end
    @audio_file = @image.audio_files.find(params[:audio_file_id])
    @audio_file.purge
    @image.reload
    render json: { status: "ok", image: @image.with_display_doc(current_user) }
  end

  def set_current_audio
    @image = current_user.images.find(params[:id])
    audio_file_id = params[:audio_file_id]
    unless audio_file_id.present?
      render json: { status: "error", message: "No audio file id provided." }
      return
    end
    @audio_file = @image.audio_files.find(audio_file_id)
    @audio_file_url = @image.default_audio_url(@audio_file)
    unless @audio_file_url.present?
      render json: { status: "error", message: "Could not find audio file url." }
      return
    end
    voice = @image.voice_from_filename(@audio_file.blob.filename.to_s)

    if @image.update(audio_url: @audio_file_url, voice: voice, use_custom_audio: voice === "custom")
      render json: { status: "ok", audio_url: @audio_file_url, filename: @audio_file.blob.filename, voice: voice, message: "Audio url updated.", image: @image.with_display_doc(@current_user) }
    else
      render json: { status: "error", message: "Could not update audio url." }
    end
  end

  private

  # A board image the current user may mutate audio on — its board is theirs.
  # nil for anyone else; admins bypass, as elsewhere.
  def owned_board_image_for_audio(id)
    scope = BoardImage.includes(:board, :image)
    return scope.find_by(id: id) if current_user.admin?

    scope.joins(:board).where(boards: { user_id: current_user.id }).find_by(id: id)
  end

  # A folder page created from a tile on a Board Builder set has to join that
  # set's builder BoardGroup (issue #586). At build time the group membership
  # and the reachable folder-tile graph are the same set, but they diverge the
  # moment the set is hand-extended: the new page is reachable from the
  # published root by tapping its tile, yet `Boards::PublishCascade` — like
  # delete and the 0-slot board count — reads GROUP MEMBERSHIP, so a page that
  # never joined is never published and a public visitor gets a 404.
  #
  # Ownership-scoped on both ends: only the current user's own groups are
  # considered, so a folder tile added on a board shared from another account
  # can't insert a board into that account's set. No-op for a board outside any
  # builder set. `add_board` is idempotent, and a failure here must never fail
  # the creation itself — the page exists and works either way.
  def attach_to_builder_set(parent_board, new_board)
    return unless parent_board && new_board

    group = parent_board.containing_builder_board_group(current_user)
    return unless group

    group.add_board(new_board)
  rescue => e
    Rails.logger.error("[ImagesController] builder set attach failed board=#{new_board&.id}: #{e.class} - #{e.message}")
  end

  # Issue #26 (IDOR): images are a shared library. A row is either PUBLIC
  # (is_private false/nil — e.g. the admin-owned symbol library, mirrors the
  # `public_img` scope) or a user's PRIVATE image. This replaces bare
  # `Image.find`, so a caller can load their own image or any public library
  # image, but a non-owner asking for someone else's PRIVATE image gets a 404
  # (ActiveRecord::RecordNotFound => 404). The public AAC library stays usable.
  # Admins may act cross-user.
  def accessible_image(id = params[:id], relation = Image)
    return relation.find(id) if current_user.admin?

    relation.where("images.is_private IS NOT TRUE OR images.user_id = ?", current_user.id).find(id)
  end

  # Gate for #generate: image generation — including the free first-fill
  # path — is only for verified accounts. Unverified accounts hold zero
  # legacy tokens and zero AI credits (see User#mark_email_verified!), but
  # the free-first-fill path never calls check_credits!, so without this an
  # unverified account could still drive paid OpenAI generation for free.
  # 403, not 402/429: this is a permission gate, not credit exhaustion or
  # rate limiting. Never renders internals — generic message only.
  def require_verified_email!
    return true if @current_user.admin?
    return true if @current_user.email_verified?

    render json: {
      error: "email_verification_required",
      message: "Please verify your email address to generate images.",
    }, status: :forbidden
    false
  end

  def check_update_board_image(saved_image_url = nil)
    saved_image_url ||= @doc.tile_url
    if params[:boardId].present?
      @board = Board.find(params[:boardId])
      if @board.user_id == current_user.id
        @board_image = @board.board_images.find_by(image_id: @image.id)
        if @board_image
          @board_image.update!(display_image_url: @doc.tile_url)
        end
        return true
      else
        Rails.logger.error("User not authorized to update board image for board: #{@board.id}")
        return false
      end
    end
  end

  def run_generate
    return if current_user.tokens < 1
    @image.update(status: "generating")
    image_prompt = image_params[:image_prompt] || image_params["image_prompt"]
    image_prompt = nil if image_prompt == @image.label
    options = { "image_prompt" => image_prompt.presence, "board_id" => params[:board_id], "style" => params[:style] }
    GenerateImageJob.perform_async(@image.id, current_user.id, options)
    current_user.remove_tokens(1)
    @board.add_to_cost(1) if @board
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, :board_id,
                                  :bg_color, :text_color, :private, :image_type, :part_of_speech, :predictive_board_id,
                                  next_words: [],
                                  audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  def attach_doc_to_image(image, user, image_data, file_extension)
    doc = image.docs.new
    doc.user = user
    doc.processed = true
    doc.source_type = Doc::SOURCE_TYPE_USER
    doc.image.attach(io: StringIO.new(Base64.decode64(image_data)),
                     filename: "img_#{image.label}_#{image.id}_doc_#{doc.id}.#{file_extension}",
                     content_type: "image/#{file_extension}")
    doc.save
    PreprocessDocTileVariantJob.perform_async(doc.id)
    doc
  end
end
