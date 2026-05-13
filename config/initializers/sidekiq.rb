Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL") { "redis://localhost:6379/0" } }
  config.logger.formatter = Sidekiq::Logger::Formatters::JSON.new
  config[:skip_default_job_logging] = true

  rails_env = Rails.env || "development"
  if rails_env == "production"
    config.logger.level = Logger::INFO
  else
    config.logger.level = Logger::DEBUG
    config.logger = Sidekiq::Logger.new("#{Rails.root}/log/sidekiq.log")
  end

  Sidekiq::Cron::Job.load_from_hash({
    "downgrade_soft_trial" => {
      "cron" => "0 2 * * *",
      "class" => "DowngradeSoftTrialJob",
      "queue" => "default",
      "description" => "Downgrade expired soft-trial Basic users to Free (runs daily at 2am UTC)",
    },
    "expire_plan_credits" => {
      "cron" => "0 * * * *",
      "class" => "ExpirePlanCreditsJob",
      "queue" => "default",
      "description" => "Zero out plan_credits_balance for users whose plan_credits_reset_at has passed. Backstop for the invoice.payment_succeeded webhook; runs hourly.",
    },
    "refresh_free_tier_credits" => {
      "cron" => "0 3 * * *",
      "class" => "RefreshFreeTierCreditsJob",
      "queue" => "default",
      "description" => "Re-grant monthly AI credits to non-subscription users (free, soft trial, MySpeak) whose plan_credits_reset_at has passed. Runs daily at 3am UTC, after DowngradeSoftTrialJob.",
    },
  })
end
