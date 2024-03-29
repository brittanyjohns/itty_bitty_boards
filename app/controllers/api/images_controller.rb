class API::ImagesController < API::ApplicationController

  def index
    if params[:user_images_only] == "1"
      @images = Image.where(image_type: nil).searchable_images_for(current_user, true).order(label: :asc).page params[:page]
    else
      @images = Image.where(image_type: nil).searchable_images_for(current_user).order(label: :asc).page params[:page]
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
        # src: url_for(image.display_image),
        src: image.display_image(current_user) ? image.display_image(current_user).url : "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
        audio: image.audio_files.first ? url_for(image.audio_files.first) : nil
      }
    end
    render json: @images_with_display_doc
  end

  def show
    @image = Image.includes(:docs).with_attached_audio_files.find(params[:id])
    @current_doc = @image.display_doc(current_user)
    @current_doc_id = @current_doc.id if @current_doc
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
        is_current: true
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
          is_current: doc.id == @current_doc_id
        } 
      end          

      }
      render json: @image_with_display_doc
    end

  def create
    puts "API::ImagesController#create image_params: #{image_params} - params: #{params}"
    @image = Image.new
    @image.user = current_user
    @image.private = true
    @image.label = image_params[:label]
    @image.save!
    doc = @image.docs.new(image_params[:docs])
    doc.user = current_user
    doc.processed = true
    puts "DOC"
    pp doc
    if doc.save
      # doc.attach_image(image_params[:display_image])
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
      @image = Image.find_or_create_by(label: label, user_id: current_user.id, private: false)
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
        is_current: true
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
          is_current: doc.id == @current_doc_id
        } 
      end          

      }
      render json: @image_with_display_doc
  end

  def find_or_create
    generate_image = params['generate_image'] == "1"
    label = image_params['label']&.downcase
    @image = Image.find_by(label: label, user_id: current_user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: false) unless @image
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
      notice += " Creating #{limit} #{'symbol'.pluralize(limit)} for image."      
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
        audio: image.audio_files.first ? url_for(image.audio_files.first) : nil
      }
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
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end
end
