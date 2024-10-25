class CreateAllAudioJob
  include Sidekiq::Job

  def perform(image_id)
    image = Image.find_by(id: image_id)
    if image.blank?
      puts "Image not found with id: #{image_id}"
      return
    end
    if image.audio_files.blank?
      puts "Creating all audio files for image: #{image.label}"
      image.create_voice_audio_files
    else
      puts "Audio files already exist for image: #{image.label}"
    end
  end
end
