class SaveAudioJob
  include Sidekiq::Job
  sidekiq_options queue: "default", retry: false

  def perform(image_ids, voice)
    images = Image.where(id: image_ids)
    images.each do |image|
      begin
      image.save_audio_file_to_s3!(voice)
      puts "\n\nNo errors in the SaveAudioJob\n\n"
      sleep 3
      rescue => e
        puts "\n**** SIDEKIQ - SaveAudioJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
