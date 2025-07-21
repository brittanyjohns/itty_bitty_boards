class SaveProfileAudioJob
  include Sidekiq::Job

  def perform(*args)
    Rails.logger.debug "\n\nSaveProfileAudioJob.perform_async(#{args})\n\n"
    profile = Profile.find_by(id: args.first)
    if profile
      begin
        profile.update_intro_audio_url
        profile.update_bio_audio_url
        profile.save!
        Rails.logger.debug "Intro audio updated for profile #{profile.intro_audio_url}"
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - SaveProfileAudioJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
