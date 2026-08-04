# Maintenance tasks for the nudge crons' per-user "already nudged" flags.
#
# Each nudge journey stamps a permanent flag in user.settings when it enqueues
# (e.g. settings["first_board_nudge_sent"] = true), so a user is nudged once and
# never again. That flag is written at ENQUEUE time, not send time — so any run
# where the journey didn't actually reach Mailchimp (unconfigured ENV pair,
# journeys disabled for the env, a trigger that errored out) left users flagged
# without ever emailing them. Those users are permanently disqualified until the
# flag is cleared, which is what :clear is for.
#
# MailchimpClient.journey_deliverable? now stops the jobs from flagging when the
# journey can't be delivered, so this should stay a rare, deliberate repair —
# not routine cleanup.
#
# Scoped to the three board-nudge journeys on purpose. Trial-reminder flags
# (rc_trial_wrap_sent) are deliberately absent: they're keyed to a specific
# trial, and clearing one re-sends a "your trial is ending" email to someone
# whose trial may have already ended.
module MailchimpNudgeFlags
  FLAGS = {
    "first_board_nudge_sent" => { journey: "first_board_nudge", job: "MailchimpFirstBoardNudgeJob" },
    "legacy_signup_nudge_sent" => { journey: "legacy_signup_nudge", job: "MailchimpLegacySignupNudgeJob" },
    "win_back_nudge_sent" => { journey: "win_back", job: "MailchimpWinBackJob" },
  }.freeze

  def self.flagged(flag)
    User.where("settings @> ?", { flag => true }.to_json)
  end
end

namespace :mailchimp do
  namespace :nudge_flags do
    desc "Report how many users carry each nudge flag, and whether its journey is deliverable"
    task :report => :environment do
      puts "Nudge flags — #{User.count} users total\n\n"

      MailchimpNudgeFlags::FLAGS.each do |flag, meta|
        count = MailchimpNudgeFlags.flagged(flag).count
        deliverable = MailchimpClient.journey_deliverable?(meta[:journey])
        status = deliverable ? "deliverable" : "NOT deliverable (unconfigured, or journeys off for this env)"

        puts format("%-26s %5d flagged   journey '%s' is %s", flag, count, meta[:journey], status)
        puts "  ^ those users are permanently excluded from #{meta[:job]}" if count.positive? && !deliverable
      end

      puts "\nClear a flag with:"
      puts "  bin/rails 'mailchimp:nudge_flags:clear[first_board_nudge_sent]'             # dry run"
      puts "  DRY_RUN=false bin/rails 'mailchimp:nudge_flags:clear[first_board_nudge_sent]'"
    end

    # Removes the flag key entirely rather than setting it to false — the jobs
    # test `settings[FLAG] == true`, but an absent key is the honest "never
    # nudged" state and keeps the settings blob from accruing dead entries.
    desc "Clear a nudge flag so those users become eligible again (DRY_RUN=false to apply, EMAIL= to scope)"
    task :clear, [:flag] => :environment do |_t, args|
      flag = args[:flag]
      unless MailchimpNudgeFlags::FLAGS.key?(flag)
        abort "Unknown flag #{flag.inspect}. One of: #{MailchimpNudgeFlags::FLAGS.keys.join(", ")}"
      end

      dry_run = ENV["DRY_RUN"] != "false"
      scope = MailchimpNudgeFlags.flagged(flag)
      scope = scope.where(email: ENV["EMAIL"]) if ENV["EMAIL"].present?

      total = scope.count
      puts "Found #{total} user(s) flagged #{flag}#{ENV["EMAIL"].present? ? " matching #{ENV["EMAIL"]}" : ""}."

      if total.zero?
        puts "Nothing to do."
        next
      end

      journey = MailchimpNudgeFlags::FLAGS[flag][:journey]
      unless MailchimpClient.journey_deliverable?(journey)
        puts "WARNING: journey '#{journey}' is not deliverable here — cleared users won't be emailed " \
             "until its ENV pair is set, and the job will skip them without re-flagging."
      end

      if dry_run
        scope.find_each { |user| puts "[dry-run] would clear #{flag} for user #{user.id} (#{user.email})" }
        puts "Dry run — nothing changed. Re-run with DRY_RUN=false to apply."
        next
      end

      cleared = 0
      scope.find_each do |user|
        settings = user.settings || {}
        next unless settings.key?(flag)

        user.update!(settings: settings.except(flag))
        cleared += 1
        puts "Cleared #{flag} for user #{user.id} (#{user.email})"
      rescue => e
        puts "FAILED for user #{user.id} (#{user.email}): #{e.message}"
      end

      puts "Cleared #{flag} for #{cleared} user(s). They're eligible again on that job's next run."
    end
  end
end
