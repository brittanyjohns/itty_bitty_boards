class DowngradeSoftTrialJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SOFT_TRIAL_DAYS = 14

  def perform
    count = 0

    expired_trial_users.find_each do |user|
      user.setup_free_limits
      user.update!(plan_type: "free")
      Rails.logger.info "DowngradeSoftTrialJob: downgraded user #{user.id} (#{user.email}) to free"
      count += 1
    rescue => e
      Rails.logger.error "DowngradeSoftTrialJob: failed for user #{user.id} - #{e.message}"
    end

    Rails.logger.info "DowngradeSoftTrialJob: completed — #{count} user(s) downgraded"
  end

  private

  def expired_trial_users
    # Target users who:
    #   - are still on the soft-trial Basic Trial plan (never upgraded or explicitly chose free)
    #   - signed up more than SOFT_TRIAL_DAYS ago
    #   - have a stripe_customer_id (skip Apple/RevenueCat-managed users)
    #   - have no paid_plan_type (skip users who've actually paid for a plan)
    User.where(plan_type: "basic_trial")
        .where("created_at <= ?", SOFT_TRIAL_DAYS.days.ago)
        .where.not(stripe_customer_id: [nil, ""])
        .where(paid_plan_type: [nil, ""])
  end
end
