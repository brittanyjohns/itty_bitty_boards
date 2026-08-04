# Daily Sidekiq-cron job that nudges signed-up users who haven't made
# their first board yet. Enqueues the Mailchimp "first_board_nudge"
# Customer Journey for each eligible user, then flags
# user.settings["first_board_nudge_sent"] so they're only nudged once.
#
# Window is 72h..48h ago (24h slop) so a single missed cron run doesn't
# permanently skip users; the per-user flag prevents re-nudging across
# runs once a user has been processed.
#
# Failure-isolated per user — a bad row logs and continues, doesn't
# poison the whole batch (matches DowngradeSoftTrialJob's pattern).
class MailchimpFirstBoardNudgeJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  WINDOW_START = 72.hours
  WINDOW_END = 48.hours
  SETTINGS_FLAG = "first_board_nudge_sent".freeze
  JOURNEY_KEY = "first_board_nudge".freeze

  def perform
    unless MailchimpClient.journey_deliverable?(JOURNEY_KEY)
      Rails.logger.warn "MailchimpFirstBoardNudgeJob: journey '#{JOURNEY_KEY}' is disabled or unconfigured — skipping without flagging anyone"
      return
    end

    count = 0

    eligible_users.find_each do |user|
      next if already_nudged?(user)
      next if user.boards.any?

      enqueue_and_flag(user)
      count += 1
    rescue => e
      Rails.logger.error "MailchimpFirstBoardNudgeJob: failed for user #{user.id} - #{e.message}"
    end

    Rails.logger.info "MailchimpFirstBoardNudgeJob: completed — #{count} user(s) nudged"
  end

  private

  # `User.non_admin` (not `where.not(role: "admin")`) — role is nullable and
  # the password-signup path never sets it, so a plain `!=` comparison is
  # NULL-false and silently drops the majority of real users.
  def eligible_users
    User
      .non_admin
      .where(created_at: WINDOW_START.ago..WINDOW_END.ago)
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
