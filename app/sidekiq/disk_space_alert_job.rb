# Hourly root-disk watchdog.
#
# Reads the root filesystem's usage with `df` and emails an admin alert when it
# crosses a warning or critical threshold. Added after a 2026-05-22 incident
# where the production disk filled silently and wedged the box during a deploy.
#
# Alerts are debounced through Redis so a sustained high-disk condition emails
# at most once per severity per DEBOUNCE_WINDOW. Staging is skipped — it shares
# the same EC2 box as production and would otherwise duplicate every alert.
class DiskSpaceAlertJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  WARN_THRESHOLD = 80
  CRITICAL_THRESHOLD = 90
  DEBOUNCE_WINDOW = 6.hours.to_i

  def perform
    return if AppEnv.staging?

    usage = root_disk_usage_percent
    return if usage.nil?

    severity = severity_for(usage)
    return unless severity
    return unless claim_alert_slot(severity)

    AdminMailer.disk_space_alert(usage: usage, severity: severity).deliver_now
    Rails.logger.warn("[DiskSpaceAlertJob] root disk at #{usage}% — #{severity} alert emailed")
  end

  # Integer use-percent of the root filesystem, or nil if `df` can't be read.
  # `-P` forces POSIX single-line output so field 5 is always the capacity.
  def root_disk_usage_percent
    fields = `df -P -k /`.lines.last&.split
    fields&.fetch(4, nil)&.delete("%")&.to_i
  rescue StandardError => e
    Rails.logger.error("[DiskSpaceAlertJob] could not read disk usage: #{e.message}")
    nil
  end

  private

  def severity_for(usage)
    return :critical if usage >= CRITICAL_THRESHOLD
    return :warn if usage >= WARN_THRESHOLD

    nil
  end

  # Reserves the right to send one alert for `severity`. Returns false when an
  # alert for that severity was already sent within DEBOUNCE_WINDOW. Separate
  # keys per severity so a warn -> critical escalation still alerts immediately.
  def claim_alert_slot(severity)
    result = Sidekiq.redis do |conn|
      conn.call("SET", "disk_space_alert:#{severity}", Time.current.to_i, "NX", "EX", DEBOUNCE_WINDOW)
    end
    result == "OK"
  end
end
