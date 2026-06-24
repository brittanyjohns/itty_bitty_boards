# config/initializers/posthog.rb
require "posthog"

# Thin wrapper around the posthog-ruby client used for SERVER-SIDE event
# capture (subscription lifecycle events fired from the Stripe webhook —
# see PosthogService). The frontend captures its own events directly via the
# JS SDK; this is only for transitions that are only knowable server-side
# (Stripe webhooks): trial_started, subscription_started, subscription_cancelled.
module PosthogClient
  DEFAULT_HOST = "https://us.i.posthog.com"

  # Memoized client. Built lazily and only when capture is enabled, so test/dev
  # don't spin up the SDK's background flush thread or require a key. Returns nil
  # when no API key is configured (callers no-op).
  def self.client
    return @client if defined?(@client) && !@client.nil?

    api_key = ENV["POSTHOG_API_KEY"].presence
    return nil if api_key.blank?

    @client = PostHog::Client.new(
      api_key: api_key,
      host: ENV["POSTHOG_HOST"].presence || DEFAULT_HOST,
      on_error: proc { |status, msg| Rails.logger.error("[PostHog] capture error status=#{status} #{msg}") },
    )
  end

  # Reset the memoized client (used by tests that toggle ENV).
  def self.reset!
    @client = nil
  end

  # Server-side capture only fires where intended. Production fires
  # automatically; staging (a separate non-prod environment) and dev/test stay
  # off unless POSTHOG_CAPTURE_ENABLED is explicitly set (used for end-to-end
  # verification).
  # Also requires an API key to be present.
  def self.enabled?
    return false if ENV["POSTHOG_API_KEY"].blank?
    return true if ENV["POSTHOG_CAPTURE_ENABLED"] == "true"

    Rails.env.production? && !AppEnv.staging?
  end
end
