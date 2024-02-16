class SaveAudioJob
  include Sidekiq::Job
  sidekiq_options queue: "default", retry: false

  def perform(image_ids, voice)
    images = Image.where(id: image_ids)
    images.each do |image|
      image.save_audio_file_to_s3!(voice)
      sleep 3
    end
  end
end
