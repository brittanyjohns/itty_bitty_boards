class SaveAudioJob
  include Sidekiq::Job
  sidekiq_options queue: "default", retry: 1

  def perform(image_ids, voice)
    puts "\n\nSaveAudioJob.perform_async(#{image_ids}, #{voice})\n\n"
    images = Image.where(id: image_ids)
    images.each do |image|
      begin
        image.find_or_create_audio_file_for_voice(voice)
        puts "\n\nNo errors in the SaveAudioJob\n\n"
        sleep 1
      rescue => e
        puts "\n**** SIDEKIQ - SaveAudioJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
