class CreatePredictiveBoardJob
  include Sidekiq::Job

  def perform(image_id, user_id)
    image = Image.find_by(id: image_id)
    if image.nil?
      Rails.logger.error "Image not found: #{image_id}"
      return
    end
    if image.next_words.blank?
      Rails.logger.error "No next words for image: #{image_id}"
      image.set_next_words!
    end

    result = image.create_predictive_board(user_id)
    if result
      Rails.logger.debug "Created predictive board: #{result.id}"
    else
      Rails.logger.error "Could not create predictive board for image: #{image_id}"
    end
  end
end
