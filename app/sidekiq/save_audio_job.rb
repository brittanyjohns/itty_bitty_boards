class SaveAudioJob
  include Sidekiq::Job

  def perform(image_ids, voice)
    images = Image.where(id: image_ids)
    images.each do |image|
      image.start_generate_audio_job if image.no_audio_saved
      sleep 1
    end
  end
end
