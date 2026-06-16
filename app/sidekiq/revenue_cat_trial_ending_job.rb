# Daily Sidekiq-cron job that sends the "trial wrapping up" reminder to
# RevenueCat (iOS/Apple) trialists ~REVENUECAT_TRIAL_REMINDER_LEAD_DAYS (default
# 3) before their free trial ends.
#
# Why a job instead of a webhook: Stripe fires a
# `customer.subscription.trial_will_end` webhook ~3 days out, which triggers
# MailchimpTrialWrapJob directly. Apple/RevenueCat send NO equivalent event, so
# we compute the reminder from settings["trial_ends_at"] — persisted by
# RevenueCat::WebhookProcessor on a TRIAL INITIAL_PURCHASE. Keying on that field
# naturally scopes this to RC trials: Stripe trialists never have it set, so they
# can't be double-nudged.
#
# Enqueues the shared MailchimpTrialWrapJob (same "trial_wrap" journey + merge
# fields as the Stripe path) and flags user.settings["rc_trial_wrap_sent"] so each
# trial is nudged once. The flag is cleared when a new trial starts (in the
# webhook), so a genuinely new trial re-arms the reminder.
#
# Lead window ENV-tunable: REVENUECAT_TRIAL_REMINDER_LEAD_DAYS (default 3). The
# daily cadence gives ~1 day of slop, so a single missed cron run doesn't
# permanently skip a user. Failure-isolated per user (a bad row logs, continues).
class RevenueCatTrialEndingJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SETTINGS_FLAG = "rc_trial_wrap_sent".freeze

  def perform
    count = 0

    eligible_users.find_each do |user|
      next if user.admin?
      next if already_nudged?(user)

      ends_at = parse_trial_end(user)
      next unless ends_at
      # Only "ending soon": in the future but within the lead window. A past
      # trial_ends_at on a still-trialing user (delayed EXPIRATION webhook) is
      # stale, not a reminder candidate.
      next unless ends_at > Time.current && ends_at <= reminder_cutoff

      MailchimpTrialWrapJob.perform_async(user.id, ends_at.to_i)
      flag_nudged!(user)
      count += 1
    rescue => e
      Rails.logger.error "RevenueCatTrialEndingJob: failed for user #{user&.id} - #{e.message}"
    end

    Rails.logger.info "RevenueCatTrialEndingJob: completed — #{count} trial(s) nudged"
  end

  private

  def lead_days
    (ENV["REVENUECAT_TRIAL_REMINDER_LEAD_DAYS"] || 3).to_i.days
  end

  def reminder_cutoff
    Time.current + lead_days
  end

  # Trialing users with a stored trial end — i.e. RevenueCat trials. Stripe
  # trialists are excluded automatically (they never get trial_ends_at).
  def eligible_users
    User
      .where(plan_status: "trialing")
      .where("settings ->> 'trial_ends_at' IS NOT NULL")
  end

  def already_nudged?(user)
    user.settings.is_a?(Hash) && user.settings[SETTINGS_FLAG] == true
  end

  def parse_trial_end(user)
    raw = user.settings["trial_ends_at"]
    raw.present? ? Time.parse(raw.to_s) : nil
  rescue ArgumentError, TypeError
    nil
  end

  def flag_nudged!(user)
    user.settings = (user.settings || {}).merge(SETTINGS_FLAG => true)
    user.save!
  end
end
