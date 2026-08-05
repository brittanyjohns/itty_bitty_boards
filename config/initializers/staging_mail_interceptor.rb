# Stops staging from delivering mail to real people.
#
# Staging runs with RAILS_ENV=production against real SMTP credentials, so any
# job or signup flow exercised there sends genuine email to whatever address
# happens to be on the record. This interceptor blocks delivery outright when
# AppEnv.staging?, which is the default: staging emails nobody.
#
# STAGING_MAIL_ALLOWLIST is the escape hatch for testing a template end to end.
# It is a comma-separated list of exact addresses (brittany@speakanyway.com) or
# domain suffixes (@speakanyway.com). Recipients that don't match are stripped
# from to/cc/bcc; a message with no allowlisted recipient left is dropped.
#
# The interceptor is registered everywhere but no-ops unless AppEnv.staging? —
# the staging check has to happen at delivery time, since autoloading AppEnv
# while initializers run is not allowed. Production and development are
# untouched. The separate E2eMailInterceptor stays pattern-scoped and applies
# in every environment.
class StagingMailInterceptor
  RECIPIENT_FIELDS = %i[to cc bcc].freeze

  def self.allowlist
    ENV["STAGING_MAIL_ALLOWLIST"].to_s.split(",").filter_map do |entry|
      entry.strip.downcase.presence
    end
  end

  def self.allowed?(address)
    normalized = address.to_s.strip.downcase
    return false if normalized.blank?

    allowlist.any? do |entry|
      entry.start_with?("@") ? normalized.end_with?(entry) : normalized == entry
    end
  end

  def self.delivering_email(message)
    return unless AppEnv.staging?

    original = RECIPIENT_FIELDS.flat_map { |field| Array(message.public_send(field)) }
    kept = []

    RECIPIENT_FIELDS.each do |field|
      recipients = Array(message.public_send(field))
      next if recipients.empty?

      allowed = recipients.select { |address| allowed?(address) }
      kept.concat(allowed)
      # nil, not [], so the header is removed rather than left empty.
      message.public_send(:"#{field}=", allowed.presence)
    end

    return if kept.any?

    message.perform_deliveries = false
    Rails.logger.info("[StagingMailInterceptor] dropped mail to #{original.join(", ")}")
  end
end

ActionMailer::Base.register_interceptor(StagingMailInterceptor)
