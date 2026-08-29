# frozen_string_literal: true

module Billing
  # Start a no-card 14-day Stripe trial directly at signup, without sending the
  # user through Stripe Checkout. Nothing is charged during a trial, so there is
  # nothing for Checkout's hosted page to collect — the redirect was pure
  # friction, and 84.5% of signups never completed it.
  #
  # This is the same subscription shape `User#ensure_partner_pro_trial_subscription!`
  # has created for partner pilots since #264: `trialing` now, a `trial_will_end`
  # reminder ~3 days out, and — if no card is ever added — a clean cancel at
  # trial end (`customer.subscription.deleted` -> downgrade to Free, content
  # retained via fallback mode) rather than an unpayable invoice.
  #
  # The Stripe webhook remains the authority for everything downstream:
  # API::WebhooksController#handle_subscription_upsert sets plan_type from the
  # Price's `metadata.plan_type`, and #handle_trial_credit_grant grants the AI
  # credit allowance. This service only creates the subscription and mirrors the
  # resulting plan state locally so the signup response is already correct.
  module StartTrial
    module_function

    TRIAL_DAYS = 14

    # Monthly only. A yearly price with a trial zeroes the Checkout amount due,
    # which breaks minimum-amount promo codes — see the long comment in
    # API::Stripe::CheckoutSessionsController. Trialists switch to yearly from
    # the billing portal once they add a card.
    PRICE_ENV_KEYS = {
      "basic" => "STRIPE_PRICE_BASIC",
      "pro" => "STRIPE_PRICE_PRO",
    }.freeze

    ELIGIBLE_PLAN_KEYS = PRICE_ENV_KEYS.keys.freeze

    # App Store and Play require in-app purchase for subscriptions, so a mobile
    # signup must never be handed a Stripe subscription. Those accounts stay on
    # Free and upgrade through RevenueCat, exactly as they do today. (Mirrors the
    # platform check that already skips Stripe customer creation at signup.)
    MOBILE_PLATFORMS = %w[ios android].freeze

    # Returns the created Stripe::Subscription, or nil when no trial was started
    # for any reason. NEVER raises: the account has already been created and
    # signed in by the time this is called, so a Stripe outage must leave the
    # user on Free rather than 500 the signup.
    def call(user, plan_key:, source: "signup", platform: nil)
      return nil if user.nil?

      plan_key = plan_key.to_s
      unless ELIGIBLE_PLAN_KEYS.include?(plan_key)
        return nil
      end

      if MOBILE_PLATFORMS.include?(platform.to_s)
        Rails.logger.info "[StartTrial] skipping stripe trial for user=#{user.id} on platform=#{platform} (IAP tier)"
        return nil
      end

      if user.admin?
        Rails.logger.info "[StartTrial] user=#{user.id} is admin; skipping trial"
        return nil
      end

      if user.stripe_subscription_id.present?
        Rails.logger.info "[StartTrial] user=#{user.id} already has subscription #{user.stripe_subscription_id}; skipping trial"
        return nil
      end

      if user.paid_plan?
        Rails.logger.info "[StartTrial] user=#{user.id} already entitled (plan_type=#{user.plan_type}); skipping trial"
        return nil
      end

      # Resolved at call time, not class load, so a deploy/test ENV change takes
      # effect without a class-cache reset (same reason as the license and
      # top-up price keys in CheckoutSessionsController).
      price_id = ENV.fetch(PRICE_ENV_KEYS.fetch(plan_key), nil).presence
      if price_id.blank?
        Rails.logger.error "[StartTrial] #{PRICE_ENV_KEYS.fetch(plan_key)} unset; user=#{user.id} stays on free"
        return nil
      end

      user.ensure_stripe_customer!

      subscription = Stripe::Subscription.create(
        customer: user.stripe_customer_id,
        items: [{ price: price_id, quantity: 1 }],
        trial_period_days: TRIAL_DAYS,
        # No card up front; if the trial ends with none on file, cancel cleanly
        # instead of cutting an unpayable invoice (the #264 reverse trial).
        trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
        metadata: { user_id: user.id, plan_key: plan_key, source: source },
      )

      mirror_plan_state!(user, subscription, plan_key)

      # The webhook's plan welcome is guarded on a plan_status TRANSITION into
      # trialing, and `mirror_plan_state!` above has already written that status
      # — so the webhook sees no transition and would never send it. Send it
      # here instead; it's idempotent per plan_type (settings
      # ["plan_welcome_sent_for"]), so the webhook re-calling it is a no-op.
      user.send_plan_welcome_email_once!(plan_key, source: "signup_trial")

      # The internal `trial_started` event is recorded by whoever CREATES the
      # trial (CheckoutSessionsController does the same at session-create); the
      # webhook deliberately fires only the PostHog mirror, so this can't
      # double-count.
      AnalyticsEvent.track(
        "trial_started",
        user_id: user.id,
        metadata: {
          plan_key: plan_key,
          require_card: false,
          payment_method_collection: "none",
          source: source,
        },
      )

      Rails.logger.info "[StartTrial] created trial subscription #{subscription.id} for user=#{user.id} plan=#{plan_key}"
      subscription
    rescue => e
      # Fail soft, always. The user keeps the account they just created and
      # lands on Free — the pre-existing behavior for every signup.
      Rails.logger.error "[StartTrial] failed to start trial for user=#{user&.id} plan=#{plan_key}: #{e.class} - #{e.message}"
      nil
    end

    # Mirror the trial locally so the signup response already reports the right
    # plan. The Stripe webhook is still authoritative and will re-assert all of
    # this; it just arrives asynchronously, and often after the response has
    # been rendered.
    #
    # Credits are deliberately NOT granted here — webhooks are the sole
    # credit-grant authority (handle_trial_credit_grant, idempotent on event id).
    def mirror_plan_state!(user, subscription, plan_key)
      # Stripe fires `customer.subscription.created` immediately, so the webhook
      # can land mid-request and write to this row. Reload before mirroring so
      # we don't save over what it just did with a stale in-memory copy.
      user.reload
      user.settings ||= {}

      user.plan_type = plan_key
      user.plan_status = subscription.status
      user.paid_plan_type = plan_key
      user.stripe_subscription_id ||= subscription.id
      user.settings["billing_interval"] = "monthly"
      user.settings["has_payment_method"] = false
      trial_end = subscription.respond_to?(:trial_end) ? subscription.trial_end : nil
      user.settings["trial_ends_at"] =
        (trial_end.present? ? Time.at(trial_end) : TRIAL_DAYS.days.from_now).iso8601

      # update!/save! rather than update_columns: `before_save :setup_limits`
      # is what applies the plan's board and communicator limits.
      user.save!
    end
  end
end
