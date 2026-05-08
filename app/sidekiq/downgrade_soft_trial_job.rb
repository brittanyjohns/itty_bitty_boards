class DowngradeSoftTrialJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SOFT_TRIAL_DAYS = 14

  def perform
    count = 0

    expired_trial_users.find_each do |user|
      user.update!(plan_type: "free")
      Rails.logger.info "DowngradeSoftTrialJob: downgraded user #{user.id} (#{user.email}) to free"
      count += 1
    rescue => e
      Rails.logger.error "DowngradeSoftTrialJob: failed for user #{user.id} - #{e.message}"
    end

    Rails.logger.info "DowngradeSoftTrialJob: completed — #{count} user(s) downgraded"

    # Re-schedule to run again in 24 hours (self-scheduling recurring job).
    # Start once via: DowngradeSoftTrialJob.perform_async
    self.class.perform_in(24.hours)
  end

  private

  def expired_trial_users
    # Target users who:
    #   - are still on the soft-trial Basic plan (never upgraded or explicitly chose free)
    #   - signed up more than SOFT_TRIAL_DAYS ago
    #   - have no paid_plan_type (i.e. never initiated a Stripe checkout for a paid plan)
    User.where(plan_type: "basic")
        .where("created_at <= ?", SOFT_TRIAL_DAYS.days.ago)
        .where(paid_plan_type: nil)
  end
end
