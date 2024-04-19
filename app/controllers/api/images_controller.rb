class API::ImagesController < API::ApplicationController
  def index
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
      # display_doc = image.display_doc(current_user)
      img_url = image.display_image(current_user) ? cdn_image_url(image.display_image(current_user)) : nil
      audio_file = image.audio_files.first
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        image_type: image.image_type,
        # display_doc: image.display_image(current_user),
        src: img_url || "https://via.placeholder.com/150x150.png?text=#{image.label_param}",
        # src: display_doc ? display_doc.attached_image_url : "https://via.placeholder.com/150x150.png?text=#{image.label_param}",
        audio: audio_file ? url_for(audio_file) : nil,
      }
    end
    render json: @images_with_display_doc
  end

  def user_images
    @images = Image.where(user_id: current_user.id).includes(:docs).order(label: :asc).page params[:page]
    @user_docs = current_user.docs.where(documentable_type: "Image").order(created_at: :desc)
    # @images = Image.joins(:docs).where(docs: { user_id: current_user.id }).order(label: :asc).page params[:page]
    @images = Image.non_menu_images.where(id: @user_docs.map(&:documentable_id)).order(label: :asc).page params[:page]
    @distinct_images = @images.distinct
    @images_with_display_doc = @distinct_images.map do |image|
      # display_doc = image.display_doc(current_user)
      img_url = image.display_image(current_user) ? cdn_image_url(image.display_image(current_user)) : nil
      audio_file = image.audio_files.first
      {
        id: image.id,

        label: image.label,
        image_type: image.image_type,
        image_prompt: image.image_prompt,
        # display_doc: image.display_image(current_user),
        src: img_url || "https://via.placeholder.com/150x150.png?text=#{image.label_param}",
        # src: display_doc ? display_doc.attached_image_url : "https://via.placeholder.com/150x150.png?text=#{image.label_param}",
        audio: audio_file ? url_for(audio_file) : nil,
      }
    end
    render json: @images_with_display_doc
  end

  def show
    @image = Image.includes(:docs).with_attached_audio_files.find(params[:id])
    @current_doc = @image.display_doc(current_user)
    @current_doc_id = @current_doc.id if @current_doc
    display_doc_img_url = @current_doc&.image&.attached? ? cdn_image_url(@current_doc.image) : nil
    @image_docs = @image.docs.with_attached_image.for_user(current_user).order(created_at: :desc)
    img_url = @image.display_image(current_user) ? cdn_image_url(@image.display_image(current_user)) : nil
    @image_with_display_doc = {
      id: @image.id,
      label: @image.label.upcase,
      image_prompt: @image.image_prompt,
      image_type: @image.image_type,
      display_doc: {
        id: @current_doc&.id,
        label: @image&.label,
        user_id: @current_doc&.user_id,
        src: display_doc_img_url || "https://via.placeholder.com/150x150.png?text=#{@image&.label}",
        # src: @current_doc&.attached_image_url,
        is_current: true,
        deleted_at: @current_doc&.deleted_at,
      },
      private: @image.private,
      user_id: @image.user_id,
      # src: url_for(@image.display_image),
      src: img_url || "https://via.placeholder.com/150x150.png?text=#{@image.label_param}",
      audio: @image.audio_files.first ? url_for(@image.audio_files.first) : nil,
      docs: @image_docs.map do |doc|
        doc_img_url = doc.image.attached? ? cdn_image_url(doc.image) : nil
        {
          id: doc.id,
          label: @image.label,
          user_id: doc.user_id,
          src: doc_img_url || "https://via.placeholder.com/150x150.png?text=#{doc.id}",
          # src: doc.image.url,
          is_current: doc.id == @current_doc_id,
        }
      end,

    }
    render json: @image_with_display_doc
  end

  def create
    puts "API::ImagesController#create image_params: #{image_params} - params: #{params}"
    @existing_image = Image.find_by(label: image_params[:label], user_id: current_user.id)
    if @existing_image
      @image = @existing_image
    else
      @image = Image.create(user: current_user, label: image_params[:label], private: true, image_prompt: image_params[:image_prompt], image_type: "User")
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
    image_prompt = "An image of #{@image.label}."
    GenerateImageJob.perform_async(@image.id, current_user.id, image_prompt)
    sleep 2
    current_user.remove_tokens(1)
    @image_docs = @image.docs.for_user(current_user).order(created_at: :desc)

    @image_with_display_doc = {
      id: @image.id,
      label: @image.label.upcase,
      image_prompt: @image.image_prompt,
      display_doc: {
        id: @current_doc&.id,
        label: @image&.label,
        user_id: @current_doc&.user_id,
        src: @current_doc&.image&.url,
        is_current: true,
      },
      private: @image.private,
      # src: url_for(@image.display_image),
      src: @image.display_image ? @image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{@image.label_param}",
      audio: @image.audio_files.first ? url_for(@image.audio_files.first) : nil,
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
        display_doc: image.display_image(current_user),
        src: url_for(image.display_image),
        audio: image.audio_files.first ? url_for(image.audio_files.first) : nil,
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
        display_doc: image.display_image(current_user),
        src: url_for(image.display_image),
        audio: image.audio_files.first ? url_for(image.audio_files.first) : nil,
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
    @image.docs.delete(@doc)
    if params[:hard_delete]
      @doc.destroy
    else
      @doc.hide!
    end
    render json: { status: "ok" }
  end

  def destroy
    @image = Image.find(params[:id])
    unless @image.user_id == current_user.id
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
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end
end
