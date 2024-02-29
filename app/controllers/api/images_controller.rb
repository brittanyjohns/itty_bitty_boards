class API::ImagesController < API::ApplicationController
  def index
    puts "API::ImagesController#index"
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
    puts "API::ImagesController#show"
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
    puts "API::ImagesController#create"
    @image = Image.new(image_params)
    @image.user = current_user
    @image.private = true

    if @image.save
      render json: @image, status: :created
    else
      render json: @image.errors, status: :unprocessable_entity
    end
  end

  private

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [])
  end
end
