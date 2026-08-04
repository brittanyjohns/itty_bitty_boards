# Daily Sidekiq-cron job that re-engages recently-dormant active users:
# people who made at least one board, then went quiet for 14-30 days.
# Enqueues the Mailchimp "win_back" Customer Journey ("your boards are
# still here") and flags user.settings["win_back_nudge_sent"] so each
# user is nudged once.
#
# Requiring >=1 board keeps this cleanly distinct from the legacy
# stalled-signup journey (#7), which targets users who NEVER made a board.
# The 14-30 day window is the recently-dormant sweet spot — past 30 days
# they fall out of the window (not re-nudged repeatedly).
#
# Thresholds ENV-tunable to match the repo's other limit knobs:
#   WIN_BACK_DORMANT_MIN_DAYS  (default 14)
#   WIN_BACK_DORMANT_MAX_DAYS  (default 30)
#   WIN_BACK_MAX_PER_RUN       (default 100) — send ceiling, 0 = no cap
#
# Failure-isolated per user (a bad row logs and continues).
class MailchimpWinBackJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SETTINGS_FLAG = "win_back_nudge_sent".freeze
  JOURNEY_KEY = "win_back".freeze

  def perform
    unless MailchimpClient.journey_deliverable?(JOURNEY_KEY)
      Rails.logger.warn "MailchimpWinBackJob: journey '#{JOURNEY_KEY}' is disabled or unconfigured — skipping without flagging anyone"
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
      next unless user.boards.any?

      enqueue_and_flag(user)
      count += 1
    rescue => e
      Rails.logger.error "MailchimpWinBackJob: failed for user #{user.id} - #{e.message}"
    end

    if capped
      Rails.logger.info "MailchimpWinBackJob: completed — #{count} user(s) nudged (hit the #{cap}/run cap; the rest go out tomorrow)"
    else
      Rails.logger.info "MailchimpWinBackJob: completed — #{count} user(s) nudged"
    end
  end

  private

  # Ceiling on one run's sends. The 14-30 day window is self-limiting in steady
  # state, but the first run after a selection fix (or any extended outage)
  # faces the whole band at once. Daily cadence drains a capped backlog fast.
  # Set WIN_BACK_MAX_PER_RUN=0 to disable the cap deliberately.
  def max_per_run
    (ENV["WIN_BACK_MAX_PER_RUN"] || 100).to_i
  end

  def dormant_min
    (ENV["WIN_BACK_DORMANT_MIN_DAYS"] || 14).to_i.days
  end

  def dormant_max
    (ENV["WIN_BACK_DORMANT_MAX_DAYS"] || 30).to_i.days
  end

  # last_sign_in_at between (max ago) and (min ago) — i.e. dormant 14-30 days.
  # `User.non_admin` is NULL-safe; `where.not(role: "admin")` is not (see
  # MailchimpFirstBoardNudgeJob).
  def eligible_users
    User
      .non_admin
      .where(last_sign_in_at: dormant_max.ago..dormant_min.ago)
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
