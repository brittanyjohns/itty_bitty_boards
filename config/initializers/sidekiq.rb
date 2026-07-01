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
      "description" => "Re-grant monthly AI credits to non-subscription users (free, basic_trial) whose plan_credits_reset_at has passed. Paid Stripe subscribers (MySpeak, Basic, Pro, Partner Pro) refresh via invoice.payment_succeeded and are skipped. Runs daily at 3am UTC, after DowngradeSoftTrialJob.",
    },
    "disk_space_alert" => {
      "cron" => "0 * * * *",
      "class" => "DiskSpaceAlertJob",
      "queue" => "default",
      "description" => "Hourly root-disk check; emails an admin at 80% (warn) / 90% (critical). Skipped on staging.",
    },
    "loaner_reclaim" => {
      "cron" => "30 2 * * *",
      "class" => "LoanerReclaimJob",
      "queue" => "default",
      "description" => "Daily reclaim sweep for loaner communicators unclaimed past LOANER_RECLAIM_AFTER_DAYS (default 90). Frees the SLP's slot.",
    },
    "mailchimp_first_board_nudge" => {
      "cron" => "0 4 * * *",
      "class" => "MailchimpFirstBoardNudgeJob",
      "queue" => "default",
      "description" => "Daily Mailchimp Customer Journey trigger for users who signed up 48-72h ago without making a board. Runs at 4am UTC, after DowngradeSoftTrialJob (2am) and RefreshFreeTierCreditsJob (3am). Flags user.settings[\"first_board_nudge_sent\"] so each user is only nudged once.",
    },
    "mailchimp_legacy_signup_nudge" => {
      "cron" => "0 5 1 * *",
      "class" => "MailchimpLegacySignupNudgeJob",
      "queue" => "default",
      "description" => "Monthly Mailchimp Customer Journey trigger (5am UTC on the 1st) re-engaging legacy stalled signups: non-admin users created over LEGACY_SIGNUP_NUDGE_AGE_DAYS (default 30) ago, no boards, no sign-in within LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS (default 30). Flags user.settings[\"legacy_signup_nudge_sent\"] so each user is only nudged once. Second-touch — may fire for users who got the 48h first_board_nudge weeks earlier.",
    },
    "mailchimp_win_back" => {
      "cron" => "30 4 * * *",
      "class" => "MailchimpWinBackJob",
      "queue" => "default",
      "description" => "Daily Mailchimp Customer Journey trigger (4:30am UTC) re-engaging recently-dormant active users: non-admin users with >=1 board whose last sign-in is WIN_BACK_DORMANT_MIN_DAYS-WIN_BACK_DORMANT_MAX_DAYS (default 14-30) days ago. Flags user.settings[\"win_back_nudge_sent\"] so each user is only nudged once.",
    },
    "revenuecat_trial_ending" => {
      "cron" => "0 5 * * *",
      "class" => "RevenueCatTrialEndingJob",
      "queue" => "default",
      "description" => "Daily (5am UTC) trial-ending reminder for RevenueCat (iOS/Apple) trialists ~REVENUECAT_TRIAL_REMINDER_LEAD_DAYS (default 3) before settings[\"trial_ends_at\"]. Apple/RevenueCat send no trial_will_end webhook (unlike Stripe), so this computes it and enqueues the shared MailchimpTrialWrapJob. Flags user.settings[\"rc_trial_wrap_sent\"] so each trial is nudged once.",
    },
    "partner_pilot_ending" => {
      "cron" => "30 5 * * *",
      "class" => "PartnerPilotEndingJob",
      "queue" => "default",
      "description" => "Daily (5:30am UTC) Partner Pro pilot sweep. Emails partners a heads-up ~PARTNER_PILOT_REMINDER_LEAD_DAYS (default 14) before plan_expires_at (flags settings[\"partner_pilot_ending_notified\"]), and flags partners past plan_expires_at with settings[\"partner_pilot_expired\"] — NO auto-downgrade. Sends Brittany an AdminMailer digest of both so she can convert/extend/downgrade by hand.",
    },
  })
end
