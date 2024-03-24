class CreateAllAudioJob
  include Sidekiq::Job

  def perform(image_id)
    image = Image.find(image_id)
    image.create_voice_audio_files
    puts "Created all audio files for image: #{image.label}"
  end
end
