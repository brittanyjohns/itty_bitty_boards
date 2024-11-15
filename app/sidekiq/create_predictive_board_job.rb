class CreatePredictiveBoardJob
  include Sidekiq::Job

  def perform(image_id, user_id, word_list)
    image = Image.find_by(id: image_id)
    if image.nil?
      Rails.logger.error "Image not found: #{image_id}"
      return
    end
    if image.next_words.blank?
      Rails.logger.error "No next words for image: #{image_id}"
      # image.set_next_words! # Temporarily disabled
    end
    user = User.find_by(id: user_id)
    if user.nil?
      Rails.logger.error "User not found: #{user_id}"
      return
    end

    if word_list.blank?
      Rails.logger.error "No word list provided"
    else
      Rails.logger.debug "Word list: #{word_list}"
      image.next_words = word_list unless image.next_words.present?
      image.save
    end

    result = image.create_predictive_board(user_id, word_list)
    if result
      Rails.logger.debug "Created predictive board: #{result.id}"
    else
      Rails.logger.error "Could not create predictive board for image: #{image_id}"
    end
  end
end
