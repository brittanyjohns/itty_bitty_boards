class CreateAllAudioJob
  include Sidekiq::Job
  sidekiq_options queue: :audio, retry: 2

  def perform(image_id, language = "en", scope = "all")
    image = Image.find_by(id: image_id)
    if image.blank?
      Rails.logger.error "Image not found with id: #{image_id}"
      return
    end
    Rails.logger.info "CreateAllAudioJob - Creating #{scope} audio files for image: #{image.label}"
    if scope == "select"
      image.create_audio_for_select_voices(language)
    else
      image.create_voice_audio_files(language)
    end
  end
end
