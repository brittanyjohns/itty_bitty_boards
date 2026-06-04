# config/initializers/mailchimp.rb
require "MailchimpMarketing"

module MailchimpClient
  def self.client
    @client ||= begin
        c = MailchimpMarketing::Client.new
        c.set_config(
          api_key: ENV.fetch("MAILCHIMP_API_KEY"),
          server: ENV.fetch("MAILCHIMP_SERVER_PREFIX"),
        )
        c
      end
  end

  # Resolve a symbolic journey key (e.g. :welcome) to the Mailchimp
  # journey_id / step_id of its API-trigger start step. IDs are per-account
  # and per-environment, so they come from ENV rather than being hardcoded:
  #   MAILCHIMP_JOURNEY_WELCOME_ID / MAILCHIMP_JOURNEY_WELCOME_STEP
  # Returns nil (caller no-ops) when the key isn't configured.
  def self.journey(key)
    prefix = "MAILCHIMP_JOURNEY_#{key.to_s.upcase}"
    id = ENV["#{prefix}_ID"]
    step = ENV["#{prefix}_STEP"]
    return nil if id.blank? || step.blank?

    { journey_id: id.to_i, step_id: step.to_i }
  end

  # Journeys send real email to real contacts, so they only fire where intended.
  # Production fires automatically; staging (shares the prod box) and dev/test
  # stay off unless MAILCHIMP_JOURNEYS_ENABLED is explicitly set (used for
  # end-to-end verification against the test audience).
  def self.journeys_enabled?
    return true if ENV["MAILCHIMP_JOURNEYS_ENABLED"] == "true"

    Rails.env.production? && !AppEnv.staging?
  end
end
