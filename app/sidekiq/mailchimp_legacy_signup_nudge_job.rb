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
#   LEGACY_SIGNUP_NUDGE_MAX_PER_RUN    (default 100) — send ceiling, 0 = no cap
#
# Failure-isolated per user (a bad row logs and continues), mirroring
# DowngradeSoftTrialJob / MailchimpFirstBoardNudgeJob.
class MailchimpLegacySignupNudgeJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SETTINGS_FLAG = "legacy_signup_nudge_sent".freeze
  JOURNEY_KEY = "legacy_signup_nudge".freeze

  def perform
    unless MailchimpClient.journey_deliverable?(JOURNEY_KEY)
      Rails.logger.warn "MailchimpLegacySignupNudgeJob: journey '#{JOURNEY_KEY}' is disabled or unconfigured — skipping without flagging anyone"
      return
    end

    count = 0
    cap = max_per_run
    capped = false

    eligible_users.find_each do |user|
      if cap.positive? && count >= cap
        capped = true
        break
      end

      next if already_nudged?(user)
      next if recently_active?(user)
      next if user.boards.any?

      enqueue_and_flag(user)
      count += 1
    rescue => e
      Rails.logger.error "MailchimpLegacySignupNudgeJob: failed for user #{user.id} - #{e.message}"
    end

    if capped
      Rails.logger.info "MailchimpLegacySignupNudgeJob: completed — #{count} user(s) nudged (hit the #{cap}/run cap; the rest go out next month)"
    else
      Rails.logger.info "MailchimpLegacySignupNudgeJob: completed — #{count} user(s) nudged"
    end
  end

  private

  # Ceiling on how many nudges one run may send. This job is the only nudge
  # that can face an unbounded backlog: its window has no upper bound (every
  # cold account ever), so a single run could email the entire back catalogue
  # at once — the fastest way to draw spam complaints and damage the sending
  # domain's reputation, which then degrades transactional mail too. The
  # per-user flag makes the work resumable, so a cap just spreads the backlog
  # over consecutive monthly runs. Set LEGACY_SIGNUP_NUDGE_MAX_PER_RUN=0 to
  # disable the cap and send everything (deliberate, not the default).
  def max_per_run
    (ENV["LEGACY_SIGNUP_NUDGE_MAX_PER_RUN"] || 100).to_i
  end

  def signup_age
    (ENV["LEGACY_SIGNUP_NUDGE_AGE_DAYS"] || 30).to_i.days
  end

  def inactive_for
    (ENV["LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS"] || 30).to_i.days
  end

  # `User.non_admin` is NULL-safe; `where.not(role: "admin")` is not (see
  # MailchimpFirstBoardNudgeJob).
  def eligible_users
    User
      .non_admin
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
    MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => JOURNEY_KEY })
    user.settings = (user.settings || {}).merge(SETTINGS_FLAG => true)
    user.save!
  end
end
