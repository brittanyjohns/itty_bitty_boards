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
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        display_doc: image.display_image,
        # src: url_for(image.display_image),
        src: image.display_image ? image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
        audio: url_for(image.audio_files.first)
      }
    end
    render json: @images_with_display_doc
  end

  def show
    @image = Image.includes(:docs).with_attached_audio_files.find(params[:id])
    @image_with_display_doc = {
      id: @image.id,
      label: @image.label,
      image_prompt: @image.image_prompt,
      display_doc: @image.display_image,
      # src: url_for(@image.display_image),
      src: @image.display_image ? @image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{@image.label_param}",
      audio: url_for(@image.audio_files.first),
      docs: @image.docs.map do |doc|
        {
          id: doc.id,
          user_id: doc.user_id,
          image: doc.image,
          documentable_id: doc.documentable_id,
          documentable_type: doc.documentable_type,
          processed: doc.processed
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
    if turbo_frame_request?
      render partial: "images", locals: { images: @images }
    else
      render :index
    end
  end


  private

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end
end
