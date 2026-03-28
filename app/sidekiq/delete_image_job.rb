class DeleteImageJob
  include Sidekiq::Job

  def perform(image_ids)
    images = Image.where(id: image_ids)
    return if images.empty?
    images.each do |image|
      image.destroy!
      Rails.logger.info "Image #{image.id} deleted"
    end
    # Do something
  end
end
