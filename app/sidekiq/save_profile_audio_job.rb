class SaveProfileAudioJob
  include Sidekiq::Job

  def perform(*args)
    profile = Profile.find_by(id: args.first)
    if profile
      begin
        profile.update_audio(:intro)
        profile.update_audio(:bio)
        profile.save!
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - SaveProfileAudioJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
