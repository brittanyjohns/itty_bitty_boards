class API::ImagesController < API::ApplicationController
  def index
    @current_user = current_user
    if params[:user_only] == "1"
      @images = Image.searchable_images_for(@current_user, true)
    else
      @images = Image.searchable_images_for(@current_user)
    end

    if params[:query].present?
      # @images = @images.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page params[:page]
      @images = Image.with_artifacts.search_by_label(params[:query]).order(label: :asc).page params[:page]
    else
      @images = @images.order(label: :asc).page params[:page]
    end

    @images_with_display_doc = @images.map do |image|
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        image_type: image.image_type,
        bg_color: image.bg_class,
        text_color: image.text_color,
        src: image.display_image_url(@current_user),
        next_words: image.next_words,
      }
    end
    render json: @images_with_display_doc
  end

  def user_images
    ActiveRecord::Base.logger.silence do
      @current_user = current_user

      @user_docs = @current_user.docs.with_attached_image.where(documentable_type: "Image").order(created_at: :desc)
      @images = Image.with_artifacts.where(id: @user_docs.map(&:documentable_id)).or(Image.where(user_id: @current_user.id)).order(label: :asc).page params[:page]
      @distinct_images = @images.distinct
      @images_with_display_doc = @distinct_images.map do |image|
        {
          id: image.id,
          label: image.label,
          image_type: image.image_type,
          bg_color: image.bg_class,
          text_color: image.text_color,
          image_prompt: image.image_prompt,
          src: image.display_image_url(@current_user),
          next_words: image.next_words,
        }
      end
      render json: @images_with_display_doc
    end
  end

  def show
    @current_user = current_user

    @image = Image.with_artifacts.find(params[:id])
    @board = Board.find_by(id: params[:board_id]) if params[:board_id].present?
    @board_image = BoardImage.find_by(board_id: @board.id, image_id: @image.id) if @board

    @image_with_display_doc = @image.with_display_doc(@current_user)
    board_image_data = {
      board_image_id: @board_image&.id,
    }
    render json: @image_with_display_doc.merge(board_image_data)
  end

  def crop
    @current_user = current_user

    label = image_params[:label]&.downcase
    image_id = params["image"]["id"]
    @doc = attach_doc_to_image(@image, @current_user, params[:cropped_image], params[:file_extension])

    if @doc.save
      @image.update(status: "finished")
      @image.reload
      render json: @image.api_view(@current_user), status: :created
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def save_temp_doc
    @current_user = current_user
    label = params[:query]&.downcase
    @existing_image = Image.find_by(label: label, user_id: @current_user.id)
    @image = nil
    if @existing_image
      @image = @existing_image
    else
      @image = Image.create(user: @current_user, label: label, private: true, image_prompt: params[:title], image_type: "User")
    end
    saved_image = @image.save_from_google(params[:imageUrl], params[:snippet], params[:title], "image/webp", @current_user.id)
    saved_image_url = saved_image.display_url
    @image.reload
    @doc = @image.docs.last
    if @doc.save
      render json: { image_url: saved_image_url, id: @image.id, doc_id: @doc.id }
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def clone
    @current_user = current_user
    @image = Image.find(params[:id])
    label_to_set = params[:new_name]&.downcase || @image.label
    @image_clone = @image.clone_with_docs(@current_user.id, label_to_set)
    voice = params[:voice] || "alloy"
    text = params[:text] || @image_clone.label
    @audio_file = @image_clone.create_audio_from_text(text, voice)
    @image_with_display_doc = @image_clone.with_display_doc(@current_user)
    render json: @image_with_display_doc
  end

  def create_audio
    @image = Image.find(params[:id])
    voice = params[:voice] || "echo"
    text = params[:text] || @image.label
    if text == @image.label
      puts "Text is the same as label"
    else
      @image.update(label: text)
    end

    @audio_file = @image.create_audio_from_text(text, voice)
    @image_with_display_doc = @image.with_display_doc(current_user)
    render json: @image_with_display_doc
  end

  def create
    @current_user = current_user

    find_first = image_params[:find_first] == "1"

    label = image_params[:label]&.downcase
    @existing_image = Image.find_by(label: label, user_id: @current_user.id)
    @image = nil
    if @existing_image && find_first
      @image = @existing_image
    else
      @image = Image.create(user: @current_user, label: label, private: true, image_prompt: image_params[:image_prompt], image_type: "User")
    end
    doc = @image.docs.new(image_params[:docs])
    doc.user = @current_user
    doc.processed = true
    if doc.save
      @image_with_display_doc = @image.attributes.merge({ display_doc: doc.attributes, src: doc.display_url })
      render json: @image.with_display_doc(current_user), status: :created
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
    else
      CreateAllAudioJob.perform_async(@image.id)
    end

    @image.create_words_from_next_words
    render json: @image
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
    label = image_params["label"]&.downcase
    is_private = image_params["private"] || false
    @image = Image.find_by(label: label, user_id: @current_user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: is_private, user_id: @current_user.id, image_prompt: image_params[:image_prompt], image_type: "User") unless @image
    @board = Board.find_by(id: image_params[:board_id]) if image_params[:board_id].present?
    @board.add_image(@image.id) if @board
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
    if !@found_image || @found_image&.docs.none?
      limit = current_user.admin? ? 10 : 5
      GetSymbolsJob.perform_async([@image.id], limit)
      notice += " Creating #{limit} #{"symbol".pluralize(limit)} for image."
    end
    @image_with_display_doc = @image.with_display_doc(@current_user)
    render json: @image_with_display_doc
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
    if @image.update(image_params)
      render json: @image, status: :ok
    else
      render json: @image.errors, status: :unprocessable_entity
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

  def hide_doc
    @image = Image.find(params[:id])
    @doc = @image.docs.find(params[:doc_id])
    unless (@doc.user_id == current_user.id) || current_user.admin?
      render json: { status: "error", message: "You are not authorized to delete this document." }
      return
    end
    begin
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
    render json: { status: "ok" }
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
    params.require(:image).permit(:label, :image_prompt, :display_image,
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
