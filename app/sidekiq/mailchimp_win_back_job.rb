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
#
# Failure-isolated per user (a bad row logs and continues).
class MailchimpWinBackJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  SETTINGS_FLAG = "win_back_nudge_sent".freeze

  def perform
    count = 0

    eligible_users.find_each do |user|
      next if already_nudged?(user)
      next if user.demo_user?
      next unless user.boards.any?

      enqueue_and_flag(user)
      count += 1
    rescue => e
      Rails.logger.error "MailchimpWinBackJob: failed for user #{user.id} - #{e.message}"
    end

    Rails.logger.info "MailchimpWinBackJob: completed — #{count} user(s) nudged"
  end

  private

  def dormant_min
    (ENV["WIN_BACK_DORMANT_MIN_DAYS"] || 14).to_i.days
  end

  def dormant_max
    (ENV["WIN_BACK_DORMANT_MAX_DAYS"] || 30).to_i.days
  end

  # last_sign_in_at between (max ago) and (min ago) — i.e. dormant 14-30 days.
  def eligible_users
    User
      .where.not(role: "admin")
      .where(last_sign_in_at: dormant_max.ago..dormant_min.ago)
  end

  def already_nudged?(user)
    user.settings.is_a?(Hash) && user.settings[SETTINGS_FLAG] == true
  end

  def enqueue_and_flag(user)
    MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "win_back" })
    user.settings = (user.settings || {}).merge(SETTINGS_FLAG => true)
    user.save!
  end
end
