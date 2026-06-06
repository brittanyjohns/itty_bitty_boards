# frozen_string_literal: true

# Server-side PostHog capture for subscription lifecycle events.
#
# These events are only knowable server-side (Stripe webhooks), so the frontend
# deliberately does NOT fire them (see itty-bitty-frontend#307). Capturing them
# here with the same distinct_id the frontend uses keeps the money-path funnel
# (pricing page -> checkout_started -> subscription_started) buildable in PostHog.
#
# distinct_id contract: the frontend identifies people as `String(user.id)`
# (src/data/analytics.ts -> posthog.identify(String(user.id))), so the backend
# MUST use the same `user.id.to_s` for events to land on the same person.
#
# Capture is env-gated (production only unless POSTHOG_CAPTURE_ENABLED=true) and
# wrapped so a PostHog failure can never break a Stripe webhook.
class PosthogService
  class << self
    # Capture an event for a user, keeping the person's `plan` property in sync.
    #
    # @param user [User]
    # @param event [String] PostHog event name (e.g. "subscription_started")
    # @param properties [Hash] event properties (e.g. { plan:, billing_interval: })
    # @param set [Hash] person properties to $set; defaults to { plan: user.plan_type }
    def capture_for_user(user, event, properties: {}, set: nil)
      return unless user
      return unless PosthogClient.enabled?

      client = PosthogClient.client
      return if client.nil?

      person_props = set.nil? ? { plan: user.plan_type } : set
      merged = properties.merge("$set" => compact(person_props))

      client.capture(
        distinct_id: user.id.to_s,
        event: event.to_s,
        properties: compact(merged),
      )
      Rails.logger.info("[PostHog] captured event=#{event} user=#{user.id}")
    rescue => e
      # Analytics must never break the webhook path.
      Rails.logger.error("[PostHog] capture_for_user failed event=#{event} user=#{user&.id}: #{e.class} - #{e.message}")
      nil
    end

    private

    # Drop nil values so they don't surface as empty PostHog properties
    # (mirrors the frontend's `clean()` helper).
    def compact(hash)
      hash.reject { |_, v| v.nil? }
    end
  end
end
