class UpdateBoardImagesJob
  include Sidekiq::Job

  def perform(image_id)
    begin
      image = Image.find(image_id)
      image.update_all_boards_image_belongs_to
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Image with id #{image_id} not found"
    rescue Exception => e
      Rails.logger.error "Error updating board images for image with id #{image_id}: #{e.message}"
    end

    # Do something
  end
end
