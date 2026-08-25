# frozen_string_literal: true

# Server-side PostHog capture for events that must be reliable regardless of
# whether the frontend JS SDK loads (ad blockers, JS errors, etc.).
#
# Covers: user signup/signin (auth events), subscription lifecycle (Stripe/
# RevenueCat webhooks), credit exhaustion, account deletion, and the product
# limits a user can hit (communicator slots, MySpeak/public pages — see
# Analytics::CommunicatorEvents). The frontend captures its own events too (see
# itty-bitty-frontend#307); overlap is fine — PostHog deduplicates by
# distinct_id + event + timestamp.
#
# distinct_id contract: the frontend identifies people as `String(user.id)`
# (src/data/analytics.ts -> posthog.identify(String(user.id))), so the backend
# MUST use the same `user.id.to_s` for events to land on the same person.
#
# Capture is env-gated (production only unless POSTHOG_CAPTURE_ENABLED=true) and
# wrapped so a PostHog failure can never break a Stripe webhook.
class PosthogService
  class << self
    # Capture an event for a user, keeping the person's identity properties in
    # sync.
    #
    # `$set` always carries plan + email + name (see `default_person_props`); an
    # explicit `set:` is MERGED OVER those defaults rather than replacing them,
    # so a caller correcting one property (`set: { plan: "free" }`) can't
    # silently drop the identity half.
    #
    # @param user [User]
    # @param event [String] PostHog event name (e.g. "subscription_started")
    # @param properties [Hash] event properties (e.g. { plan:, billing_interval: })
    # @param set [Hash] person properties to $set, merged over the defaults
    def capture_for_user(user, event, properties: {}, set: nil)
      return unless user
      return unless PosthogClient.enabled?

      client = PosthogClient.client
      return if client.nil?

      person_props = default_person_props(user).merge(set || {})
      merged = properties.merge(
        "$set" => compact(person_props),
        # posthog-ruby sends the APP SERVER's IP, so without this every
        # server-side event geo-resolves to the EC2 box's city and overwrites
        # the person's real location with it. Geo comes from the frontend SDK
        # or from nowhere.
        "$geoip_disable" => true,
      )

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

    # Person properties stamped on EVERY server-side capture.
    #
    # email/name are here so a support request can be joined to PostHog
    # activity. Server-side capture is the only signal we get from a user who
    # never accepted the cookie banner — the frontend is `identified_only` +
    # opt-out-by-default (#312), so `identify()` never produces an identified
    # person — and without these the record is an unlabelled id.
    def default_person_props(user)
      {
        plan: user.plan_type,
        email: user.email,
        name: user.name,
      }
    end

    # Drop nil values so they don't surface as empty PostHog properties
    # (mirrors the frontend's `clean()` helper).
    def compact(hash)
      hash.reject { |_, v| v.nil? }
    end
  end
end
