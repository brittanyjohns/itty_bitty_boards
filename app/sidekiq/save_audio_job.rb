class SaveAudioJob
  include Sidekiq::Job
  sidekiq_options queue: :audio, retry: 2

  def perform(image_ids, voice, board_image_id = nil)
    images = Image.where(id: image_ids)
    images.each do |image|
      begin
        audio_file = image.find_or_create_audio_file_for_voice(voice, "en")
        unless audio_file
          Rails.logger.error "Failed to find or create audio file for Image ID #{image.id} with voice #{voice}. Skipping update for BoardImage ID #{board_image_id}."
          next
        end
        if board_image_id
          board_image = image.board_images.find_by(id: board_image_id)
          if board_image
            board_image.audio_url = image.default_audio_url(audio_file)
            voice_value = voice || "polly:kevin"
            board_image.voice = voice_value
            board_image.save!
          else
            Rails.logger.error "BoardImage with ID #{board_image_id} not found for Image ID #{image.id}. Cannot update audio_url."
          end
        end
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.error "BoardImage with ID #{board_image_id} not found for Image ID #{image.id}. Cannot update audio_url. Error: #{e.message}"
      rescue StandardError => e
        Rails.logger.error "Error processing Image ID #{image.id} in SaveAudioJob: #{e.message}"
      end
    end
  end
end
