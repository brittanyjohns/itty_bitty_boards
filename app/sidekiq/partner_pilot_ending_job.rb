# Daily Sidekiq-cron sweep over Partner Pro pilots that keeps the 3-month
# pilot window meaningful WITHOUT auto-downgrading anyone.
#
# Background: a `partner_pro` signup grants Pro-level access with
# `plan_expires_at = now + 3.months`, but nothing ever reads that date — so
# partners silently keep Pro forever and Brittany gets no signal to have the
# convert/extend/downgrade conversation. Partners are high-value B2B leads
# (SLP champions, schools), so a hard auto-drop is the wrong tool. Instead this
# job:
#
#   1. REMINDER pass — partners whose `plan_expires_at` is within the lead
#      window (PARTNER_PILOT_REMINDER_LEAD_DAYS, default 14) are added to the
#      admin digest once (flagged settings["partner_pilot_ending_notified"]).
#      The partner-facing nudge itself is now owned by Stripe's `trial_will_end`
#      webhook + the Mailchimp trial-wrap journey (Phase 2 made the pilot a real
#      no-card Stripe trial), so this pass no longer emails the partner unless
#      PARTNER_PILOT_LEGACY_REMINDER=true.
#   2. EXPIRED pass — partners whose `plan_expires_at` has passed and who are
#      still `partner_pro` get flagged settings["partner_pilot_expired"] (with
#      partner_pilot_expired_at) so they're findable and counted once. NO plan
#      change — expiry handling stays a human decision (see rake
#      partners:pilot_status and the admin digest below).
#
# Both passes feed a single AdminMailer digest to Brittany so she can act. The
# flags make the job idempotent: a partner is reminded once and included in the
# digest once, no matter how many days the cron runs before she deals with them.
#
# Downgrade is no longer this job's concern: Phase 2 put the pilot on a real
# Stripe no-card trial, so expiry now flows through the reverse-trial webhooks
# (trial lapses → cancel → `customer.subscription.deleted` → Free). This job is
# now digest-only — an admin heads-up so Brittany can convert/extend before the
# auto-downgrade lands. It can be retired once that flow is trusted in prod.
class PartnerPilotEndingJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  REMINDER_FLAG = "partner_pilot_ending_notified".freeze
  EXPIRED_FLAG = "partner_pilot_expired".freeze

  def perform
    expiring = []
    expired = []

    partner_pilots.find_each do |user|
      ends_at = user.plan_expires_at
      next if ends_at.nil?

      if ends_at <= Time.current
        # Pilot window has ended. Flag for review (once) — never downgrade.
        next if flagged?(user, EXPIRED_FLAG)

        flag_expired!(user)
        expired << user
      elsif ends_at <= reminder_cutoff
        # Ending soon and not yet counted for the admin digest.
        next if flagged?(user, REMINDER_FLAG)

        # The partner-facing "your pilot is wrapping up" nudge is now owned by
        # Stripe's `trial_will_end` webhook + the Mailchimp trial-wrap journey
        # (the pilot is a real no-card Stripe trial as of Phase 2). This job no
        # longer emails the partner directly — it only feeds the admin digest so
        # Brittany still gets a heads-up to convert/extend. Set
        # PARTNER_PILOT_LEGACY_REMINDER=true to re-enable the bespoke email.
        if ENV["PARTNER_PILOT_LEGACY_REMINDER"] == "true"
          PartnerMailer.pilot_ending_email(user).deliver_now
        end
        flag!(user, REMINDER_FLAG)
        expiring << user
      end
    rescue => e
      Rails.logger.error "PartnerPilotEndingJob: failed for user #{user&.id} - #{e.message}"
    end

    if expiring.any? || expired.any?
      AdminMailer.partner_pilot_review(expiring: expiring, expired: expired).deliver_now
    end

    Rails.logger.info "PartnerPilotEndingJob: completed — #{expiring.size} ending soon, #{expired.size} newly expired"
  end

  private

  def lead_days
    (ENV["PARTNER_PILOT_REMINDER_LEAD_DAYS"] || 14).to_i.days
  end

  def reminder_cutoff
    Time.current + lead_days
  end

  def partner_pilots
    User.where(plan_type: "partner_pro").where.not(plan_expires_at: nil)
  end

  def flagged?(user, key)
    user.settings.is_a?(Hash) && user.settings[key] == true
  end

  def flag!(user, key)
    user.settings = (user.settings || {}).merge(key => true)
    user.save!
  end

  def flag_expired!(user)
    user.settings = (user.settings || {}).merge(
      EXPIRED_FLAG => true,
      "partner_pilot_expired_at" => Time.current.iso8601,
    )
    user.save!
  end
end
