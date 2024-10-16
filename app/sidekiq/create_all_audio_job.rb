class CreateAllAudioJob
  include Sidekiq::Job

  def perform(image_id)
    image = Image.find(image_id)
    if image.audio_files.blank?
      puts "Creating all audio files for image: #{image.label}"
      image.create_voice_audio_files
    else
      puts "Audio files already exist for image: #{image.label}"
    end
  end
end
