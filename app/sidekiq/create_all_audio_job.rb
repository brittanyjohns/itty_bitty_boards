class CreateAllAudioJob
  include Sidekiq::Job

  def perform(image_id, language = "en")
    image = Image.find_by(id: image_id)
    if image.blank?
      puts "Image not found with id: #{image_id}"
      return
    end
    puts "Creating audio files for image: #{image.label}"
    image.create_voice_audio_files(language)
  end
end
