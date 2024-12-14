class DeleteImageJob
  include Sidekiq::Job

  def perform(image_id)
    image = Image.find(image_id)
    image.destroy!
    Rails.logger.info "Image #{image_id} deleted"
    # Do something
  end
end
