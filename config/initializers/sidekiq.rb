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
  })
end
