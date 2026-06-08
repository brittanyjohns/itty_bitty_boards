# frozen_string_literal: true

module RevenueCat
  # Processes RevenueCat (Apple/Google IAP) webhooks, reaching parity with the
  # Stripe webhook in API::WebhooksController. Mirrors Stripe semantics: a
  # purchase/renewal grants plan credits, an expiration downgrades to free, a
  # cancellation (auto-renew off, still entitled) is analytics-only, a billing
  # issue keeps access during the grace period.
  #
  # RevenueCat's app_user_id IS the Rails user.id (the app configures Purchases
  # with String(user.id)), so user lookup is a plain find_by(id:).
  class WebhookProcessor
    PROVIDER = "revenuecat"

    Result = Struct.new(:status, :http_status, keyword_init: true)

    # RevenueCat authenticates webhooks with a shared secret it sends verbatim
    # in the Authorization header (not an HMAC signature, unlike Stripe).
    def self.authorized?(header)
      expected = ENV["REVENUECAT_WEBHOOK_AUTH_HEADER"].to_s
      return false if expected.blank?

      ActiveSupport::SecurityUtils.secure_compare(header.to_s, expected)
    end

    def initialize(payload)
      @payload = payload || {}
      @event = @payload["event"] || {}
    end

    def process
      event_id = @event["id"]
      event_type = @event["type"]
      environment = @event["environment"]

      return ok("ignored_no_event_id") if event_id.blank?

      # In real production, ignore SANDBOX events so test purchases can't grant
      # real plans. Honor them everywhere else (dev/test/staging) for testing.
      if environment == "SANDBOX" && production_live?
        Rails.logger.info "[RCWebhook] ignoring SANDBOX event #{event_id} in production"
        return ok("ignored_sandbox")
      end

      user = find_user
      claim = claim_event!(event_id, event_type, environment, user&.id)
      return ok("already_processed") unless claim

      unless user
        Rails.logger.error "[RCWebhook] no user for app_user_id=#{@event["app_user_id"].inspect} (#{event_type} #{event_id})"
        return ok("no_user_found")
      end
      return ok("admin_skipped") if user.admin?

      Rails.logger.info "[RCWebhook] processing #{event_type} #{event_id} for user=#{user.id}"
      dispatch(event_type, user)
      ok("ok")
    end

    private

    def dispatch(type, user)
      case type
      when "INITIAL_PURCHASE", "NON_RENEWING_PURCHASE"
        handle_purchase(user, fire_started: true)
      when "RENEWAL"
        handle_purchase(user, fire_started: false)
      when "PRODUCT_CHANGE"
        handle_purchase(user, fire_started: false)
      when "UNCANCELLATION"
        user.update!(plan_status: "active")
      when "CANCELLATION"
        handle_cancellation(user) # analytics only — still entitled until expiry
      when "EXPIRATION"
        handle_expiration(user)
      when "BILLING_ISSUE"
        user.update!(plan_status: "past_due") # keep access during grace period
      when "SUBSCRIPTION_PAUSED"
        Billing::PlanTransitions.apply_free_plan(user, "paused")
      when "TRANSFER"
        handle_transfer
      else
        Rails.logger.info "[RCWebhook] ignoring unhandled type=#{type}"
      end
    end

    # Purchase / renewal / upgrade: set the plan active and (re)grant the tier's
    # monthly credits for the new period. grant_plan! is a full reset, not
    # additive, and dedups on the event id, so replays are safe.
    def handle_purchase(user, fire_started:)
      plan_type = resolve_plan_type
      return unless plan_type

      user.plan_type = plan_type
      user.plan_status = "active"
      interval = RevenueCat::PlanMapping.billing_interval_for_product(@event["product_id"])
      user.settings["billing_interval"] = interval if interval.present?
      user.setup_limits
      user.save!

      CreditService.grant_plan!(
        user,
        amount: CreditService.monthly_credits_for(plan_type),
        period_end: expiration_time || 30.days.from_now,
        stripe_event_id: rc_event_token,
        metadata: {
          provider: PROVIDER,
          plan_type: plan_type,
          product_id: @event["product_id"],
          source: @event["type"],
        },
      )

      # fire_started distinguishes a genuine start (INITIAL/NON_RENEWING) from a
      # renewal/product-change. An IAP user goes straight from free(active) to
      # paid(active) with no intermediate status, so we can't guard on a status
      # transition the way Stripe does — the flag is the signal. Event-level
      # idempotency prevents a re-delivered purchase from double-firing.
      fire_subscription_started(user, plan_type) if fire_started
    end

    # Auto-renew turned off but the user keeps access until the period ends — no
    # plan change here; EXPIRATION does the actual downgrade later.
    def handle_cancellation(user)
      AnalyticsEvent.track(
        "subscription_canceled",
        user_id: user.id,
        metadata: { plan_type: user.plan_type, provider: PROVIDER, reason: @event["cancel_reason"], product_id: @event["product_id"] },
      )
      PosthogService.capture_for_user(
        user, "subscription_cancelled",
        properties: { plan: user.plan_type, reason: @event["cancel_reason"] }
      )
    end

    def handle_expiration(user)
      cancelled_plan = user.plan_type
      Billing::PlanTransitions.apply_free_plan(user, "canceled")
      AnalyticsEvent.track(
        "subscription_canceled",
        user_id: user.id,
        metadata: { plan_type: cancelled_plan, provider: PROVIDER, reason: "expiration" },
      )
      PosthogService.capture_for_user(
        user, "subscription_cancelled",
        properties: { plan: cancelled_plan, reason: "expiration" }
      )
    end

    # TRANSFER moves entitlements between app_user_ids (e.g. restore on a new
    # account). The event carries no product/entitlement, so we downgrade the
    # losing ids and re-verify the gaining ids via the REST API. Logged at WARN
    # for manual review while iOS volume is low.
    def handle_transfer
      Rails.logger.warn "[RCWebhook] TRANSFER event=#{@event["id"]} from=#{@event["transferred_from"].inspect} to=#{@event["transferred_to"].inspect}"

      numeric_user_ids(@event["transferred_from"]).each do |uid|
        u = User.find_by(id: uid)
        Billing::PlanTransitions.apply_free_plan(u, "transferred") if u && !u.admin?
      end

      numeric_user_ids(@event["transferred_to"]).each do |uid|
        u = User.find_by(id: uid)
        next unless u && !u.admin?

        result = RevenueCat::Client.new.verified_plan_for(u.id.to_s)
        next unless result.ok? && result.plan_type

        u.plan_type = result.plan_type
        u.plan_status = "active"
        u.setup_limits
        u.save!
        CreditService.grant_plan!(
          u,
          amount: CreditService.monthly_credits_for(result.plan_type),
          period_end: result.expiration || 30.days.from_now,
          stripe_event_id: "#{rc_event_token}_to_#{uid}",
          metadata: { provider: PROVIDER, source: "TRANSFER", plan_type: result.plan_type },
        )
      end
    end

    def fire_subscription_started(user, plan_type)
      AnalyticsEvent.track(
        "subscription_started",
        user_id: user.id,
        metadata: { plan_type: plan_type, provider: PROVIDER, product_id: @event["product_id"], store: @event["store"] },
      )
      PosthogService.capture_for_user(
        user, "subscription_started",
        properties: {
          plan: plan_type,
          billing_interval: RevenueCat::PlanMapping.billing_interval_for_product(@event["product_id"]),
        }
      )
    end

    # --- helpers -------------------------------------------------------------

    def resolve_plan_type
      RevenueCat::PlanMapping.resolve_plan_type(
        entitlement_ids: Array(@event["entitlement_ids"]).presence || [@event["entitlement_id"]].compact,
        product_id: @event["product_id"],
      )
    end

    # Webhook timestamps arrive as epoch milliseconds (REST uses ISO8601).
    def expiration_time
      ms = @event["expiration_at_ms"] || @event["expires_date_ms"]
      ms.present? ? Time.at(ms.to_i / 1000.0) : nil
    end

    def find_user
      candidates = [@event["app_user_id"], @event["original_app_user_id"], *Array(@event["aliases"])]
      numeric_user_ids(candidates).each do |uid|
        user = User.find_by(id: uid)
        return user if user
      end
      nil
    end

    # Keep only numeric Rails ids; skip RevenueCat anonymous ids ($RCAnonymousID:…).
    def numeric_user_ids(ids)
      Array(ids).compact.map(&:to_s).select { |s| s.match?(/\A\d+\z/) }.uniq
    end

    # Namespaced idempotency token reusing credit_transactions.stripe_event_id.
    def rc_event_token
      "rc_#{@event["id"]}"
    end

    def claim_event!(event_id, event_type, environment, user_id)
      # Savepoint (requires_new) so a duplicate's unique-index violation rolls
      # back just this INSERT instead of poisoning any surrounding transaction.
      ActiveRecord::Base.transaction(requires_new: true) do
        ProcessedWebhookEvent.create!(
          provider: PROVIDER,
          event_id: event_id,
          event_type: event_type,
          environment: environment,
          user_id: user_id,
          payload: @event,
          processed_at: Time.current,
        )
      end
      true
    rescue ActiveRecord::RecordNotUnique
      # Lost the index race against a concurrent delivery.
      false
    rescue ActiveRecord::RecordInvalid => e
      # The model's uniqueness validation usually catches the dup first. Only
      # swallow it when it's genuinely already recorded — re-raise otherwise so
      # real validation bugs aren't hidden.
      raise e unless ProcessedWebhookEvent.exists?(provider: PROVIDER, event_id: event_id)
      false
    end

    def production_live?
      Rails.env.production? && !AppEnv.staging?
    end

    def ok(status)
      Result.new(status: status, http_status: :ok)
    end
  end
end
