class CreateAllAudioJob
  include Sidekiq::Job
  sidekiq_options queue: :audio, retry: 5

  # Polly enforces per-region TPS limits. When a burst (e.g. a board language
  # change fanning out across many images) exceeds them, Polly raises
  # ThrottlingException. Back off well past Sidekiq's default a few seconds
  # so the queue actually drains instead of retrying into the same throttle.
  sidekiq_retry_in do |count, exception|
    case exception
    when Aws::Polly::Errors::ThrottlingException
      (30 * (count + 1)) + rand(15) # 30s, 60s, 90s, 120s, 150s (+ jitter)
    end
  end

  def perform(image_id, language = "en", scope = "all")
    image = Image.find_by(id: image_id)
    if image.blank?
      Rails.logger.error "Image not found with id: #{image_id}"
      return
    end
    if scope == "select"
      image.create_audio_for_select_voices(language)
    else
      image.create_voice_audio_files(language)
    end
  end
end
