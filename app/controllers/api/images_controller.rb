class API::ImagesController < API::ApplicationController
  def index
    if params[:user_images_only] == "1"
      @images = Image.searchable_images_for(current_user, true)
    else
      @images = Image.searchable_images_for(current_user)
    end

    puts "images.count: #{@images.count}"
    puts "params[:query]: #{params[:query]}"

    if params[:query].present?
      # @images = @images.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page params[:page]
      @images = Image.with_artifacts.search_by_label(params[:query]).order(label: :asc).page params[:page]
    else
      @images = @images.order(label: :asc).page params[:page]
    end

    puts "after query images.count: #{@images.count}"

    @images_with_display_doc = @images.map do |image|
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        image_type: image.image_type,
        bg_color: image.bg_class,
        text_color: image.text_color,
        src: image.display_image_url(current_user),
        next_words: image.next_words,
      # audio: image.default_audio_url
      }
    end
    render json: @images_with_display_doc
  end

  def user_images
    @user_docs = current_user.docs.with_attached_image.where(documentable_type: "Image").order(created_at: :desc)
    @images = Image.with_artifacts.where(id: @user_docs.map(&:documentable_id)).order(label: :asc).page params[:page]
    @distinct_images = @images.distinct
    @images_with_display_doc = @distinct_images.map do |image|
      # display_doc = image.display_doc(current_user)
      # audio_file = image.audio_files.first
      {
        id: image.id,
        label: image.label,
        image_type: image.image_type,
        bg_color: image.bg_class,
        text_color: image.text_color,
        image_prompt: image.image_prompt,
        src: image.display_image_url(current_user),
        next_words: image.next_words,
      # src: display_doc ? display_doc.attached_image_url : "https://via.placeholder.com/150x150.png?text=#{image.label_param}",
      # audio: audio_file ? url_for(audio_file) : nil,
      # audio: image.default_audio_url,
      }
    end
    render json: @images_with_display_doc
  end

  def show
    @image = Image.with_artifacts.find(params[:id])
    @current_doc = @image.display_doc(current_user)
    puts "Current Doc: #{@current_doc.inspect}"
    @current_doc_id = @current_doc.id if @current_doc
    @image_docs = @image.docs.with_attached_image.for_user(current_user).order(created_at: :desc)
    @user_image_boards = @image.boards.where(user_id: current_user.id)
    @image_with_display_doc = {
      id: @image.id,
      label: @image.label.upcase,
      image_prompt: @image.image_prompt,
      image_type: @image.image_type,
      bg_color: @image.bg_class,
      text_color: @image.text_color,
      user_image_boards: @user_image_boards,
      display_doc: {
        id: @current_doc&.id,
        label: @image&.label,
        user_id: @current_doc&.user_id,
        src: @image.display_image_url(current_user),
        # src: @current_doc&.attached_image_url,
        is_current: true,
        deleted_at: @current_doc&.deleted_at,
      },
      private: @image.private,
      user_id: @image.user_id,
      next_words: @image.next_words,
      no_next: @image.no_next,
      # src: url_for(@image.display_image),
      src: @image.display_image_url(current_user),
      # src: @image.display_doc(current_user)&.attached_image_url || "https://via.placeholder.com/150x150.png?text=#{@image.label_param}",
      # audio: @image.default_audio_url,
      # audio: @image.audio_files.first ? url_for(@image.audio_files.first) : nil,
      docs: @image_docs.map do |doc|
        {
          id: doc.id,
          label: @image.label,
          user_id: doc.user_id,
          # src: doc.image.url,
          src: doc.display_url,
          is_current: doc.id == @current_doc_id,
        }
      end,
    }
    render json: @image_with_display_doc
  end

  def crop
    label = image_params[:label]&.downcase
    image_id = params["image"]["id"]
    if image_id.present?
      @existing_image = Image.find(image_id)
    else
      @existing_image = Image.find_by(label: label, user_id: current_user.id)
    end
    if @existing_image
      @image = @existing_image
    else
      @image = Image.create(user: current_user, label: label, private: true, image_prompt: image_params[:image_prompt], image_type: "User")
    end
    @doc = @image.docs.new
    @doc.user = current_user
    @doc.processed = true
    file_extension = params[:file_extension]
    doc_tmp_id = @image.docs.count + 1
    filename = "img_#{@image.id}_img_doc_#{doc_tmp_id}_cropped.#{file_extension}"
    @doc.image.attach(io: StringIO.new(Base64.decode64(params[:cropped_image])),
                      filename: filename,
                      content_type: "image/#{file_extension}")
    if @doc.save
      @image.update(status: "finished")
      @image.reload
      render json: @image.api_view(current_user), status: :created
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  def create
    label = image_params[:label]&.downcase
    @existing_image = Image.find_by(label: label, user_id: current_user.id)
    if @existing_image
      @image = @existing_image
    else
      @image = Image.create(user: current_user, label: label, private: true, image_prompt: image_params[:image_prompt], image_type: "User")
    end
    doc = @image.docs.new(image_params[:docs])
    doc.user = current_user
    doc.processed = true
    if doc.save
      render json: @image, status: :created
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
      puts "Setting next words: #{@image.next_words}"
      @image.save
    else
      # @image.set_next_words!
      CreateAllAudioJob.perform_async(@image.id)
    end
    puts "Next Words: #{@image&.next_words.count}"
    puts "Next images: #{@image&.next_images.count}"
    @image.create_words_from_next_words
    render json: @image
  end

  def create_symbol
    puts "API::ImagesController#create_symbol params: #{params}"
    @image = Image.find(params[:id])
    limit = current_user.admin? ? 10 : 1
    GetSymbolsJob.perform_async([@image.id], limit)
    render json: { status: "ok", message: "Creating #{limit} symbols for image." }
  end

  def new
    @image = Image.new
    puts "API::ImagesController#new image_params: #{image_params} - params: #{params}"
  end

  def generate
    if !params[:id].blank?
      @image = Image.find(params[:id])
    else
      label = image_params[:label].present? ? image_params[:label].downcase : image_params[:image_prompt]
      puts "Label: #{label}"
      @image = Image.find_or_create_by(label: label, user_id: current_user.id, private: false, image_prompt: image_params[:image_prompt], image_type: "Generated")
    end
    @image.update(status: "generating")
    puts "\n\nPARAMS: #{params.inspect}\n\n"
    # image_prompt = "An image of #{@image.label}."
    image_prompt = image_params[:image_prompt] || image_params["image_prompt"]
    GenerateImageJob.perform_async(@image.id, current_user.id, image_prompt)
    current_user.remove_tokens(1)
    @image_docs = @image.docs.for_user(current_user).order(created_at: :desc)

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
      src: @image.display_image_url(current_user),
      audio: @image.default_audio_url,
      # src: url_for(@image.display_image),
      # src: @image.display_image ? @image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{@image.label_param}",
      # audio: @image.audio_files.first ? url_for(@image.audio_files.first) : nil,
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
    generate_image = params["generate_image"] == "1"
    label = image_params["label"]&.downcase
    @image = Image.find_by(label: label, user_id: current_user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: false, user_id: current_user.id, image_prompt: image_params[:image_prompt], image_type: "User") unless @image
    @board = Board.find_by(id: image_params[:board_id]) if image_params[:board_id].present?

    @board.add_image(@image.id) if @board
    if @found_image
      notice = "Image found!"
      @found_image.update(status: "finished") unless @found_image.finished?
      run_generate if generate_image
    else
      if current_user.tokens > 0 && generate_image
        notice = "Generating image..."
        run_generate
      elsif !generate_image
        notice = "Image created! Remember you can always upload your own image or generate one later."
      else
        notice = "You don't have enough tokens to generate an image."
      end
    end
    if !@found_image || @found_image&.docs.none?
      puts "New Image or no docs"
      limit = current_user.admin? ? 10 : 5
      GetSymbolsJob.perform_async([@image.id], limit)
      notice += " Creating #{limit} #{"symbol".pluralize(limit)} for image."
    end
    @image_with_display_doc = @image.with_display_doc(current_user)
    render json: @image_with_display_doc
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
    if params[:user_images_only] == "1"
      @images = Image.searchable_images_for(current_user, true).order(label: :asc).page params[:page]
    else
      @images = Image.searchable_images_for(current_user).order(label: :asc).page params[:page]
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
        src: image.display_image_url(current_user),
        audio: image.default_audio_url,
      # display_doc: image.display_image(current_user),
      # src: url_for(image.display_image),
      # audio: image.audio_files.first ? url_for(image.audio_files.first) : nil,
      }
    end
  end

  def predictive
    if params["ids"].present?
      @images = Image.where(id: params["ids"])
    else
      puts "No ids - #{params}"
    end
    @images = @images.order(label: :asc).page params[:page]
    @images_with_display_doc = @images.map do |image|
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        src: image.display_image_url(current_user),
        audio: image.default_audio_url,

      # display_doc: image.display_image(current_user),
      # src: url_for(image.display_image),
      # audio: image.audio_files.first ? url_for(image.audio_files.first) : nil,
      }
    end
    render json: @images_with_display_doc
  end

  def hide_doc
    @image = Image.find(params[:id])
    @doc = @image.docs.find(params[:doc_id])
    unless @doc.user_id == (current_user.id || current_user.admin?)
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
end
