class API::ImagesController < API::ApplicationController
  def index
    @current_user = current_user
    sort_order = params[:sort_order] || "asc"
    sort_field = params[:sort_field] || "label"
    puts "Sort order: #{sort_order} -- Sort field: #{sort_field}"
    if sort_field == "undefined" || sort_field.blank?
      sort_field = "label"
    end
    if sort_order == "undefined" || sort_order.blank?
      sort_order = "asc"
    end
    if params[:user_only] == "1"
      # @images = Image.searchable_images_for(@current_user, true)
      @images = Image.searchable.with_artifacts.where(user_id: @current_user.id)
    else
      # @images = Image.searchable_images_for(@current_user)
      @images = Image.searchable.with_artifacts.where(user_id: [nil, User::DEFAULT_ADMIN_ID])
    end

    if params[:query].present?
      @images = @images.search_by_label(params[:query]).order("#{sort_field} #{sort_order}").page params[:page]
    else
      @images = @images.order("#{sort_field} #{sort_order}").page params[:page]
    end

    render json: @images.map { |image| image.api_view(@current_user) }
  end

  def user_images
    render json: { status: "error", message: "User images endpoint is deprecated.  Please use the images endpoint with the user_only parameter." }
  end

  def show
    @current_user = current_user

    puts "Show image params: #{params}"
    id = params[:id]
    puts "Image ID: #{id}"

    @image = Image.find(id)
    @board = Board.find_by(id: params[:board_id]) if params[:board_id].present?

    @image_with_display_doc = @image.with_display_doc(@current_user, @board)
    render json: { image: @image_with_display_doc, board: @board&.api_view(@current_user) }
  end

  def crop
    @current_user = current_user

    label = image_params[:label]&.downcase
    image_id = params["image"]["id"]
    @image = Image.find(image_id) if image_id.present?
    @image = Image.find_by(label: label, user_id: @current_user.id) unless @image
    @image = Image.public_img.find_by(label: label) unless @image
    @image = Image.create(label: label, user_id: @current_user.id) unless @image
    @doc = attach_doc_to_image(@image, @current_user, params[:cropped_image], params[:file_extension])

    if @doc.save
      @image.update(status: "finished")
      @image.reload
      render json: @image.api_view(@current_user), status: :created
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  # Google Search API
  def save_temp_doc
    @current_user = current_user
    if params[:imageId].present?
      @existing_image = Image.find(params[:imageId])
    end
    label = params[:query]&.downcase
    @existing_image = Image.find_by(label: label, user_id: @current_user.id) unless @existing_image
    @image = nil
    if @existing_image
      @image = @existing_image
    else
      @image = Image.create(user: @current_user, label: label, private: true, image_prompt: params[:title], image_type: "User")
    end
    saved_image = @image.save_from_url(params[:imageUrl], params[:snippet], params[:title], "image/webp", @current_user.id)
    saved_image_url = saved_image.display_url
    @image.update_all_boards_image_belongs_to(saved_image_url, false, @current_user.id)
    # UpdateBoardImagesJob.perform_async(@image.id, saved_image_url)
    @doc = @image.docs.last
    user_docs_to_delete = @current_user.user_docs.where(image_id: @image.id)
    user_docs_to_delete.destroy_all
    user_doc = UserDoc.create!(user_id: current_user.id, doc_id: @doc.id, image_id: @doc.documentable_id)
    did_update = @doc.update(current: true)
    if @doc.save
      render json: { image_url: saved_image_url, id: @image.id, doc_id: @doc.id }
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def merge
    puts "Merging images params: #{params}"
    @current_user = current_user
    @image = Image.find(params[:id])
    @image_to_merge = Image.find(params[:merge_image_id])
    @docs = @image_to_merge.docs
    @docs.each do |doc|
      doc.documentable = @image
      doc.user = @current_user
      result = doc.save!
    end
    @board_images = BoardImage.where(image_id: @image_to_merge.id)
    @board_images.each do |board_image|
      board_image.update(image_id: @image.id, display_image_url: @image.src_url)
      board_image.save_defaults
    end

    @image_to_merge.update(status: "marked_for_deletion")
    DeleteImageJob.perform_in(1.minute, @image_to_merge.id)
    @image.reload
    render json: @image.with_display_doc(@current_user)
  end

  def clone
    @current_user = current_user
    @image = Image.with_artifacts.find(params[:id])
    label_to_set = params[:new_name]&.downcase || @image.label
    user_id = @current_user.id
    make_dynamic = params[:make_dynamic] == "1"
    word_list = params[:word_list] ? params[:word_list].compact : nil
    @image_clone = @image.clone_with_current_display_doc(user_id, label_to_set, make_dynamic, word_list)
    voice = params[:voice] || "alloy"
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

    # @audio_file = @image_clone.create_audio_from_text(text, voice)
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
    @image = Image.find(params[:id])
    unless @image.user_id == current_user.id || current_user.admin?
      render json: { status: "error", message: "You are not authorized to upload audio for this image." }
      return
    end
    @file_name = params[:file_name] || params[:audio_file].original_filename
    @file_name = @file_name.downcase.gsub(" ", "-")
    @file_name = @file_name.downcase.gsub("_", "-")
    @file_name_to_save = "#{@file_name}_custom"
    puts "File name to save: #{@file_name_to_save}"

    puts "Audio file: #{params[:audio_file]}"

    @audio_file = @image.audio_files.attach(io: params[:audio_file], filename: @file_name_to_save)
    new_audio_file_url = @image.default_audio_url(@audio_file.first)
    puts "New audio file url: #{new_audio_file_url}"
    voice = @image.voice_from_filename(@audio_file.blob.filename.to_s)

    if @image.update(audio_url: new_audio_file_url, voice: @image.voice_from_filename(@file_name_to_save), use_custom_audio: true)
      @image_with_display_doc = @image.with_display_doc(current_user)
      render json: { status: "ok", image: @image_with_display_doc, audio_file: @audio_file.first, audio_url: new_audio_file_url, filename: @file_name_to_save, voice: @image.voice_from_filename(@file_name_to_save) }
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def create_audio
    @image = Image.with_artifacts.find(params[:id])
    voice = params[:voice] || "alloy"
    text = params[:text] || @image.label
    if text != @image.label
      @image.update(label: text)
    end

    @audio_file = @image.create_audio_from_text(text, voice)
    @image.reload
    @image_with_display_doc = @image.with_display_doc(current_user)
    render json: @image_with_display_doc
  end

  def generate_audio
    input_text = params[:text]

    begin
      client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"], log_errors: true)

      voice = params[:voice] || "alloy"
      user_speed = current_user.settings["voice"]["speed"] || 1.0
      speed = params[:speed].blank? ? user_speed : params[:speed]

      valid_speeds = 0.25..4.0
      speed = valid_speeds.include?(speed.to_f) ? speed.to_f : 1.0

      response = client.audio.speech(
        parameters: {
          model: "tts-1",
          voice: voice,
          speed: speed,
          input: input_text,
        },
      )

      audio_data = response
      send_data audio_data, type: "audio/mpeg", disposition: "attachment", filename: "#{input_text.parameterize}_#{voice}_#{speed}.mp3"
    rescue StandardError => e
      Rails.logger.error("Error generating audio: #{e.message}")
      render json: { error: "Failed to generate audio" }, status: :internal_server_error
    end
  end

  def create
    @current_user = current_user

    find_first = image_params[:find_first] == "1"
    duplicate_image = image_params[:duplicate] == "1"

    label = image_params[:label]&.downcase
    @existing_image = Image.find_by(label: label, user_id: @current_user.id)
    @image = nil
    if @existing_image && find_first && !duplicate_image
      @image = @existing_image
    else
      @image = Image.create(user: @current_user, label: label, private: true, image_prompt: image_params[:image_prompt], image_type: "User")
    end
    doc = @image.docs.new(image_params[:docs])
    doc.user = @current_user
    doc.processed = true
    if doc.save
      @image_with_display_doc = @image.attributes.merge({ display_doc: doc.attributes, src: doc.display_url })
      render json: @image.with_display_doc(@current_user), status: :created
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def add_doc
    @image = Image.find(params[:id])
    @doc = @image.docs.new(image_params[:docs])
    @doc.user = current_user
    @doc.processed = true
    if @doc.save
      render json: @image, status: :created
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def set_next_words
    @image = Image.find(params[:id])
    if params[:next_words].present?
      @image.next_words = params[:next_words]&.compact_blank
      @image.save
      if @image.predictive_board&.id === Board.predictive_default.id
      else
        @board = @image.predictive_board
        if @board
          new_words = @image.next_words.keep_if { |word| !@board.words.include?(word) }
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
    @image = Image.find(params[:id])
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

    use_preview_model = current_user.admin? || current_user.settings["use_preview_model"]

    Rails.logger.info("Creating predictive board for image: #{@image.label} -- use_preview_model: #{use_preview_model} -- word_list: #{word_list}")
    board_settings[:board_id] = params[:board_id] if params[:board_id].present?
    board = @image.create_predictive_board(user_id, word_list, use_preview_model, board_settings)
    board.display_image_url = @board_image.display_image_url if @board_image

    puts "Board created: #{board.inspect}"
    unless @board_image && board
      render json: { status: "error", message: "Could not create predictive board." }
      return
    end
    if @board_image.update(predictive_board_id: board.id)
      render json: { status: "ok", message: "Creating predictive board for image.", board: board }
    else
      render json: { status: "error", message: "Could not create predictive board." }
    end
  end

  def create_symbol
    @image = Image.find(params[:id])
    limit = current_user.admin? ? 20 : 1
    @image.update(status: "generating") unless @image.generating?
    @image.generate_matching_symbol(limit)
    @image.update(status: "finished") unless @image.finished?
    render json: { status: "ok", message: "Creating #{limit} symbols for image.", image: @image }
  end

  def new
    @image = Image.new
  end

  def generate
    @current_user = current_user

    if !params[:id].blank?
      @image = Image.find(params[:id])
    else
      label = image_params[:label].present? ? image_params[:label].downcase : image_params[:image_prompt]
      @image = Image.find_or_create_by(label: label, user_id: @current_user.id, private: false, image_prompt: image_params[:image_prompt], image_type: "Generated")
    end
    @image.update(status: "generating")
    image_prompt = image_params[:image_prompt] || image_params["image_prompt"]
    GenerateImageJob.perform_async(@image.id, @current_user.id, image_prompt)
    @current_user.remove_tokens(1)
    @image_docs = @image.docs.for_user(@current_user).order(created_at: :desc)

    @image_with_display_doc = {
      id: @image.id,
      label: @image.label.upcase,
      image_prompt: @image.image_prompt,
      bg_color: @image.bg_class,
      image_type: @image.image_type,
      text_color: @image.text_color,
      display_doc: {
        id: @current_doc&.id,
        label: @image&.label,
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
          label: @image.label,
          user_id: doc.user_id,
          src: doc.image.url,
          is_current: doc.id == @current_doc_id,
        }
      end,

    }
    render json: @image_with_display_doc
  end

  def find_or_create
    @current_user = current_user

    generate_image = params["generate_image"] == "1"
    duplicate_image = params["duplicate"] == "1"
    label = image_params["label"]&.downcase
    puts "Label: #{label} -- Generate Image: #{generate_image} -- Duplicate Image: #{duplicate_image}"

    is_private = image_params["private"] || false
    @image = Image.find_by(label: label, user_id: @current_user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: is_private, user_id: @current_user.id, image_prompt: image_params[:image_prompt], image_type: "User") unless @image || duplicate_image
    @board = Board.find_by(id: image_params[:board_id]) unless image_params[:board_id].blank?
    if @board.nil? && duplicate_image && !generate_image && @image&.id
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
    label = params[:label].downcase
    @image = Image.find_by(label: label, user_id: @current_user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    if @image
      @image_with_display_doc = @image.with_display_doc(@current_user)
      render json: @image_with_display_doc
    else
      render json: { status: "error", message: "Image not found." }
    end
  end

  def update
    @image = Image.find(params[:id])
    puts "Image params: #{image_params}"

    if @image.update(image_params)
      render json: @image.with_display_doc(current_user)
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def clear_current
    @image = Image.find(params[:id])
    puts "Params: #{params}"
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
      # @image_with_display_doc = {
      #   id: @image.id,
      #   label: @image.label.upcase,
      #   image_prompt: @image.image_prompt,
      #   image_type: @image.image_type,
      #   bg_color: @image.bg_class,
      #   text_color: @image.text_color,
      #   display_doc: {
      #     id: nil,
      #     label: @image.label,
      #     user_id: nil,
      #     src: nil,
      #     is_current: true,

      #   },
      #   private: @image.private,
      #   user_id: @image.user_id,
      #   next_words: @image.next_words,
      #   no_next: @image.no_next,
      #   src: nil,
      #   docs: @image_docs.map do |doc|
      #     {
      #       id: doc.id,
      #       label: @image.label,
      #       user_id: doc.user_id,
      #       src: params[:update_all] ? nil : doc.display_url,
      #       is_current: doc.id == @current_doc_id,
      #     }
      #   end,
      # }

      render json: @image_with_display_doc
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
        label: image.label,
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
        label: image.label,
        image_prompt: image.image_prompt,
        src: image.display_image_url(current_user),
        audio: image.default_audio_url,
      }
    end
    render json: @images_with_display_doc
  end

  def describe
    @image = Image.find(params[:id])
    image_url = params[:image_url] || @image.display_image_url(current_user)
    puts "Describing image #{@image.label}: #{image_url}"
    @image.update(status: "describing")
    @image.describe_image(image_url)
    @image.reload
    render json: @image.with_display_doc(current_user)
  end

  def hide_doc
    @image = Image.find(params[:id])
    @doc = @image.docs.find(params[:doc_id])
    unless (@doc.user_id == current_user.id) || current_user.admin?
      render json: { status: "error", message: "You are not authorized to delete this document." }
      return
    end
    begin
      doc_url = @doc.display_url
      if @image.src_url == doc_url
        @image.update(src_url: nil)
      end
      @image.docs.delete(@doc)
      if params[:hard_delete]
        @doc.destroy
      else
        @doc.hide!
      end
    rescue FrozenError => e
      # Ignore frozen error
      render json: { status: "ok", message: e.message } and return
    rescue StandardError => e
      render json: { status: "error", message: e.message } and return
    end

    render json: { status: "ok" }
  end

  def destroy
    @image = Image.find(params[:id])
    unless @image.user_id == current_user.id || current_user.admin?
      render json: { status: "error", message: "You are not authorized to delete this image." }
      return
    end
    @image.destroy
    render json: { status: "ok" }
  end

  def sample_voices
    @voices = Image.sample_audio_files
    render json: @voices
  end

  def destroy_audio
    @image = Image.find(params[:id])
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
    @image = Image.find(params[:id])
    unless current_user.admin? || @image.user_id == current_user.id
      render json: { status: "error", message: "You are not authorized to update the audio url for this image." }
      return
    end
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

  def run_generate
    return if current_user.tokens < 1
    @image.update(status: "generating")
    GenerateImageJob.perform_async(@image.id, current_user.id)
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
    doc.image.attach(io: StringIO.new(Base64.decode64(image_data)),
                     filename: "img_#{image.id}_img_doc_#{doc.id}_cropped.#{file_extension}",
                     content_type: "image/#{file_extension}")
    doc.save
    doc
  end
end
