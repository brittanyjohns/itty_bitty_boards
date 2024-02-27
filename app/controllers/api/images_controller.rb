class API::ImagesController < ApplicationController
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
end
