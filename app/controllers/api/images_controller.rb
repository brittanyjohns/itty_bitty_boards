class API::ImagesController < API::ApplicationController
  def index
    @images = Image.includes(:docs).with_attached_audio_files.first(16)
    @images_with_display_doc = @images.map do |image|
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        display_doc: image.display_image,
        src: url_for(image.display_image),
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
      src: url_for(@image.display_image),
      audio: url_for(@image.audio_files.first)
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


  private

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end
end
