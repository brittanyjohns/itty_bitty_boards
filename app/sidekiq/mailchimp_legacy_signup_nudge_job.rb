# Monthly Sidekiq-cron job that re-engages legacy stalled signups: users
# who created an account a while ago, never made a board, and haven't
# signed in recently. Enqueues the Mailchimp "legacy_signup_nudge"
# Customer Journey for each, then flags
# user.settings["legacy_signup_nudge_sent"] so each user is nudged once.
#
# Distinct from MailchimpFirstBoardNudgeJob (#2), which targets the
# 48-72h fresh-signup window with different copy. This is a slower,
# second-touch re-engagement for accounts that went cold — it *may* fire
# for a user who already got the #2 nudge weeks earlier (different email,
# different framing), but only ever once thanks to the per-user flag.
#
# Thresholds are ENV-tunable to match the repo's other limit knobs:
#   LEGACY_SIGNUP_NUDGE_AGE_DAYS       (default 30) — min account age
#   LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS  (default 30) — min days since last sign-in
#
# Failure-isolated per user (a bad row logs and continues), mirroring
# DowngradeSoftTrialJob / MailchimpFirstBoardNudgeJob.
class MailchimpLegacySignupNudgeJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SETTINGS_FLAG = "legacy_signup_nudge_sent".freeze

  def perform
    count = 0

    eligible_users.find_each do |user|
      next if already_nudged?(user)
      next if user.demo_user?
      next if recently_active?(user)
      next if user.boards.any?

      enqueue_and_flag(user)
      count += 1
    rescue => e
      Rails.logger.error "MailchimpLegacySignupNudgeJob: failed for user #{user.id} - #{e.message}"
    end

    Rails.logger.info "MailchimpLegacySignupNudgeJob: completed — #{count} user(s) nudged"
  end

  private

  def signup_age
    (ENV["LEGACY_SIGNUP_NUDGE_AGE_DAYS"] || 30).to_i.days
  end

  def inactive_for
    (ENV["LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS"] || 30).to_i.days
  end

  def eligible_users
    User
      .where.not(role: "admin")
      .where("created_at < ?", signup_age.ago)
  end

  def already_nudged?(user)
    user.settings.is_a?(Hash) && user.settings[SETTINGS_FLAG] == true
  end

  # Skip anyone who's signed in recently — they're not a cold "you said
  # yes a while back and disappeared" case. Users who never signed in
  # again (last_sign_in_at older than the window, or only their signup
  # sign-in) still qualify.
  def recently_active?(user)
    user.last_sign_in_at.present? && user.last_sign_in_at > inactive_for.ago
  end

  def enqueue_and_flag(user)
    MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "legacy_signup_nudge" })
    user.settings = (user.settings || {}).merge(SETTINGS_FLAG => true)
    user.save!
  end
end
