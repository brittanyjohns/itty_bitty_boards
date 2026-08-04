# Daily Sidekiq-cron job that nudges signed-up users who haven't made
# their first board yet. Enqueues the Mailchimp "first_board_nudge"
# Customer Journey for each eligible user, then flags
# user.settings["first_board_nudge_sent"] so they're only nudged once.
#
# Eligibility is a CATCH-UP window, not a single-day band: 48h..14d after
# signup. The original 72h..48h band gave each user exactly one day of
# eligibility, so two consecutive missed cron runs (or any Sidekiq outage
# spanning a day) aged that day's cohort out permanently — never flagged,
# never nudged, and nothing swept for them afterwards. Once-only delivery is
# guaranteed by the per-user flag, not by the narrowness of the window, so the
# window can be wide without risking a second send.
#
# Thresholds are ENV-tunable to match the repo's other limit knobs:
#   FIRST_BOARD_NUDGE_MIN_AGE_HOURS  (default 48) — let them settle in first
#   FIRST_BOARD_NUDGE_MAX_AGE_DAYS   (default 14) — past this it's stale; the
#                                     monthly legacy_signup_nudge covers them
#   FIRST_BOARD_NUDGE_MAX_PER_RUN    (default 100) — send ceiling, 0 = no cap
#
# Failure-isolated per user — a bad row logs and continues, doesn't
# poison the whole batch (matches DowngradeSoftTrialJob's pattern).
class MailchimpFirstBoardNudgeJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SETTINGS_FLAG = "first_board_nudge_sent".freeze
  JOURNEY_KEY = "first_board_nudge".freeze

  def perform
    unless MailchimpClient.journey_deliverable?(JOURNEY_KEY)
      Rails.logger.warn "MailchimpFirstBoardNudgeJob: journey '#{JOURNEY_KEY}' is disabled or unconfigured — skipping without flagging anyone"
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
      next if user.boards.any?

      enqueue_and_flag(user)
      count += 1
    rescue => e
      Rails.logger.error "MailchimpFirstBoardNudgeJob: failed for user #{user.id} - #{e.message}"
    end

    if capped
      Rails.logger.info "MailchimpFirstBoardNudgeJob: completed — #{count} user(s) nudged (hit the #{cap}/run cap; the rest go out tomorrow)"
    else
      Rails.logger.info "MailchimpFirstBoardNudgeJob: completed — #{count} user(s) nudged"
    end
  end

  private

  def min_age
    (ENV["FIRST_BOARD_NUDGE_MIN_AGE_HOURS"] || 48).to_i.hours
  end

  def max_age
    (ENV["FIRST_BOARD_NUDGE_MAX_AGE_DAYS"] || 14).to_i.days
  end

  # Bounds the catch-up sweep. The window is 14 days wide, so the first run
  # after a fix (or after any extended outage) can face a backlog rather than
  # one day's signups. Daily cadence means a capped backlog drains quickly.
  def max_per_run
    (ENV["FIRST_BOARD_NUDGE_MAX_PER_RUN"] || 100).to_i
  end

  # `User.non_admin` (not `where.not(role: "admin")`) — role is nullable and
  # the password-signup path never sets it, so a plain `!=` comparison is
  # NULL-false and silently drops the majority of real users.
  #
  # No explicit order: find_each forces primary-key order and ignores any
  # scoped order anyway — and ascending id is chronological for users, which
  # is what a capped run wants (serve the ones closest to aging out first).
  def eligible_users
    User
      .non_admin
      .where(created_at: max_age.ago..min_age.ago)
  end

  def already_nudged?(user)
    user.settings.is_a?(Hash) && user.settings[SETTINGS_FLAG] == true
  end

  def enqueue_and_flag(user)
    MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => JOURNEY_KEY })
    user.settings = (user.settings || {}).merge(SETTINGS_FLAG => true)
    user.save!
  end
end
