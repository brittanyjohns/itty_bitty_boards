# app/controllers/api/stripe/checkout_sessions_controller.rb
class API::Stripe::CheckoutSessionsController < API::ApplicationController
  before_action :authenticate_token!

  NO_CC_KEY = "NOCC".freeze

  # Hosts we trust as Stripe Checkout `success_url` / `cancel_url` targets.
  # We derive the redirect host from the incoming request's Origin/Referer
  # so Netlify preview deploys "just work" without per-deploy env vars, but
  # we don't want to be an open redirect — Stripe will happily send users
  # to whatever success_url we hand it. Anything not on this list falls
  # back to ENV["FRONT_END_URL"].
  ALLOWED_FRONTEND_HOSTS = [
    /\Alocalhost\z/,
    /\A127\.0\.0\.1\z/,
    /\A(.+\.)?speakanyway\.com\z/,
    /\A(.+\.)?netlify\.app\z/,
    /\A(.+\.)?hatchboxapp\.com\z/,
  ].freeze

  PLAN_PRICE_IDS = {
    "free" => nil,
    "basic" => ENV.fetch("STRIPE_PRICE_BASIC", nil),
    "pro" => ENV.fetch("STRIPE_PRICE_PRO", nil),
    "basic_yearly" => ENV.fetch("STRIPE_PRICE_BASIC_YEAR", nil),
    "pro_yearly" => ENV.fetch("STRIPE_PRICE_PRO_YEAR", nil),
    "partner_pro" => ENV.fetch("STRIPE_PRICE_PARTNER_PRO", nil),
  }.freeze

  # 5-Year licenses are a ONE-TIME Stripe payment (mode: "payment"), not a
  # subscription — Basic $199 / Pro $499, web only. Entitlement lasts
  # LICENSE_YEARS via plan_expires_at, enforced by PlanExpiryJob. Resolved from
  # ENV at request time so deploy/test env changes take effect without a
  # class-cache reset. The webhook grants the plan (handle_license_completed);
  # the checkout session only carries the metadata it reads.
  LICENSE_PRICE_ENV_KEYS = {
    "basic_5yr" => "STRIPE_PRICE_BASIC_5YR",
    "pro_5yr" => "STRIPE_PRICE_PRO_5YR",
  }.freeze

  LICENSE_YEARS = 5

  # Resolved at request time (not class load) so changes to ENV in deploy
  # configs or in test setup take effect without a class-cache reset.
  TOPUP_PRICE_ENV_KEYS = {
    "small" => "STRIPE_PRICE_TOPUP_SMALL",
    "medium" => "STRIPE_PRICE_TOPUP_MEDIUM",
    "large" => "STRIPE_PRICE_TOPUP_LARGE",
  }.freeze

  # Fallback if a Stripe Price lacks `metadata.credit_amount`. Keep in sync
  # with docs/credits-handoff.md and docs/stripe-setup.md.
  TOPUP_CREDIT_AMOUNTS = {
    "small" => 100,
    "medium" => 500,
    "large" => 1500,
  }.freeze

  def create
    plan_key = params[:plan_key].to_s
    price_id = PLAN_PRICE_IDS[plan_key]
    promo_code = params[:promo_code].to_s.strip
    # Which CTA/page initiated checkout (itty-bitty-frontend#505). Threaded
    # from the frontend so the server-side `checkout_started` carries the same
    # `source` the (best-effort) client event does; defaulted so it's never nil.
    source = params[:source].to_s.strip.presence || "web_checkout"

    if plan_key == "free" || price_id.blank?
      current_user.update!(plan_type: "free", plan_status: "active")
      render json: { url: "#{frontend_base_url}/home" } and return
    end
    is_partner = plan_key == "partner_pro"

    # No-card reverse trial is the default (issue #264): a Basic/Pro trial
    # starts with no card on file and, if it ends without an upgrade, the
    # account drops to Free (handled in API::WebhooksController) rather than
    # being charged or stranded `past_due`.
    #
    # The card-required arm ("always") is the A/B experiment's control. It can
    # be forced per-request via params[:require_card] (so the PostHog
    # experiment can drive the split from the frontend) or globally via the
    # STRIPE_PAYMENT_METHOD_COLLECTION=always env override.
    require_card = params[:require_card].to_s == "true" ||
                   ENV["STRIPE_PAYMENT_METHOD_COLLECTION"] == "always"
    payment_method_collection = require_card ? "always" : "if_required"
    ensure_customer!

    trial_days = 14
    cancel_url = "#{frontend_base_url}/onboarding"
    if is_partner
      cancel_url = "#{frontend_base_url}/onboarding/partner"
    end

    # Explicit no-card bypass (legacy NOCC promo / param). Always wins over the
    # card-required arm — used for partner pilots and support comps.
    bypass_payment_required = params[:bypass_payment_required] == "true" || promo_code&.upcase == NO_CC_KEY

    if bypass_payment_required
      payment_method_collection = "if_required"
      require_card = false
    end

    promo_code_str = nil
    if plan_key == "partner_pro"
      promo_code_str = ENV["STRIPE_PARTNER_PILOT_PROMO"] || "PARTNERPILOT26"
    elsif promo_code.present? && promo_code != NO_CC_KEY
      promo_code_str = promo_code
    end
    if promo_code_str.present?
      promo = Stripe::PromotionCode.list(
        code: promo_code_str,
        active: true,
        limit: 1,
      ).data.first
    end

    session_params = {
      mode: "subscription",
      customer: current_user.stripe_customer_id,
      # PostHog distinct_id is String(user.id); threading it through Checkout
      # lets Stripe-originated events attribute to the same person and helps
      # close the identity-stitching gap (itty_bitty_boards#452).
      client_reference_id: current_user.id.to_s,
      line_items: [{ price: price_id, quantity: 1 }],
      success_url: "#{frontend_base_url}/billing/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: cancel_url,
      metadata: { user_id: current_user.id, plan_key: plan_key, source: source },
      payment_method_collection: payment_method_collection,
    }

    if promo.present?
      session_params[:discounts] = [
        { promotion_code: promo.id },
      ]
    else
      session_params[:allow_promotion_codes] = true
    end

    # Only layer the no-card reverse trial (#264) onto non-promo checkouts. A
    # promo means the user is committing to a discounted plan now, so we
    # subscribe at the discounted rate immediately (a card is collected when
    # there's an amount due today).
    #
    # This is also required for correctness: a promotion code with a
    # minimum-amount restriction — e.g. the FOUNDING coupon's $50 floor, the
    # mechanism that gates it to the yearly plans — is validated against the
    # Checkout Session's amount, and a 14-day trial zeroes that amount to $0. So
    # Stripe rejects the code with "This promotion code cannot be redeemed
    # because the associated purchase does not meet the minimum amount
    # requirement" (prod 400s, 2026-07-07). Without the trial the checkout
    # carries the plan's real price (yearly $80/$200 ≥ $50), the minimum is
    # satisfied, and the discount applies to the subscription.
    apply_trial = promo.blank?
    if apply_trial
      session_params[:subscription_data] = {
        trial_period_days: trial_days,
        # When a no-card trial ends with no payment method on file, cancel the
        # subscription instead of generating an unpayable invoice. The resulting
        # `customer.subscription.deleted` webhook downgrades the user to Free in
        # fallback mode (issue #264 + #255) — never an unexpected charge, never
        # stuck `past_due`. Harmless on the card-required arm: a payment method
        # is present, so this end_behavior never triggers and the card is charged.
        trial_settings: {
          end_behavior: { missing_payment_method: "cancel" },
        },
      }
    end

    session = Stripe::Checkout::Session.create(session_params)
    current_user.update!(paid_plan_type: plan_key)
    # Server-side `checkout_started` (itty_bitty_boards#452 / frontend #505).
    # The frontend fires this too but it's routinely dropped when the page
    # unloads to Stripe before PostHog's batch flushes, so the reliable capture
    # is here at session-create. `plan`/`billing_interval` mirror the frontend +
    # `subscription_started` shape so the CTA → checkout_started →
    # checkout_completed funnel lines up.
    PosthogService.capture_for_user(
      current_user,
      "checkout_started",
      properties: {
        plan: plan_base(plan_key),
        billing_interval: billing_interval_for(plan_key),
        kind: "subscription",
        source: source,
      },
    )
    # Measure trial starts so trial→paid conversion is computable against the
    # later `subscription_started` event (issue #264 A/B instrumentation). Only
    # fires when a trial was actually created — promo checkouts subscribe
    # immediately (no trial), so they don't pollute the trial→paid metric.
    if apply_trial
      AnalyticsEvent.track(
        "trial_started",
        user_id: current_user.id,
        metadata: {
          plan_key: plan_key,
          require_card: require_card,
          payment_method_collection: payment_method_collection,
        },
      )
    end
    Rails.logger.info "session: #{session.inspect}"
    render json: { url: session.url }
  rescue StandardError => e
    Rails.logger.error "Error creating checkout session: #{e.class} - #{e.message}"
    render json: { error: "Failed to create checkout session" }, status: :bad_request
  end

  # POST /api/stripe/checkout_sessions/topup
  # Body: { pack_key: "small"|"medium"|"large", quantity: 1 }
  # Creates a one-time payment Checkout Session for a credit pack.
  # On payment success the Stripe webhook (checkout.session.completed with
  # metadata.kind=topup) calls CreditService.grant_topup! — see
  # API::WebhooksController.
  def topup
    pack_key = params[:pack_key].to_s
    env_key = TOPUP_PRICE_ENV_KEYS[pack_key]
    price_id = env_key.present? ? ENV[env_key].presence : nil
    quantity = [params[:quantity].to_i, 1].max
    source = params[:source].to_s.strip.presence || "web_checkout"

    if price_id.blank?
      render json: { error: "Unknown or unconfigured pack_key" }, status: :bad_request
      return
    end

    ensure_customer!

    credit_amount = TOPUP_CREDIT_AMOUNTS[pack_key].to_i

    # NOTE: `payment_method_collection` is only valid on subscription-mode
    # Checkout Sessions. For one-time payment mode (top-up packs), Stripe
    # rejects the request with "You can only set `payment_method_collection`
    # if there are recurring prices." Leaving it off; Stripe's default for
    # mode=payment already collects a payment method.
    session = Stripe::Checkout::Session.create(
      mode: "payment",
      customer: current_user.stripe_customer_id,
      # Same distinct_id threading as subscription checkout (#452).
      client_reference_id: current_user.id.to_s,
      line_items: [{ price: price_id, quantity: quantity }],
      # Match the frontend's existing /billing/success route, which reads
      # ?type=topup&credits=N to render the "credits added" screen
      # (itty-bitty-frontend Welcome.tsx). Stripe interpolates
      # CHECKOUT_SESSION_ID; the other params are baked in here.
      success_url: "#{frontend_base_url}/billing/success?session_id={CHECKOUT_SESSION_ID}&type=topup&credits=#{credit_amount * quantity}",
      cancel_url: "#{frontend_base_url}/billing",
      allow_promotion_codes: true,
      metadata: {
        kind: "topup",
        user_id: current_user.id,
        pack_key: pack_key,
        credit_amount: credit_amount * quantity,
        source: source,
      },
    )
    # Server-side `checkout_started` for top-ups, mirroring the subscription
    # path and the `checkout_completed` topup event (kind: "topup"). `plan` is
    # the user's current tier — a topup doesn't pick one.
    PosthogService.capture_for_user(
      current_user,
      "checkout_started",
      properties: {
        plan: current_user.plan_type,
        kind: "topup",
        pack_key: pack_key,
        source: source,
      },
    )
    render json: { url: session.url }
  rescue Stripe::StripeError => e
    Rails.logger.error "[Topup] Stripe error creating topup session: #{e.class} - #{e.message}"
    render json: { error: "Failed to create top-up session" }, status: :bad_request
  rescue StandardError => e
    Rails.logger.error "[Topup] Unexpected error creating topup session: #{e.class} - #{e.message}"
    render json: { error: "Failed to create top-up session" }, status: :bad_request
  end

  # POST /api/stripe/checkout_sessions/license
  # Body: { plan_key: "basic_5yr"|"pro_5yr", promo_code: "...", source: "..." }
  # Creates a ONE-TIME payment Checkout Session for a 5-Year license. On payment
  # success the Stripe webhook (checkout.session.completed with
  # metadata.kind=license) calls handle_license_completed, which sets the plan,
  # a 5-year plan_expires_at, and grants the first month's credits — see
  # API::WebhooksController. Modeled on #topup (mode: "payment").
  def license
    plan_key = params[:plan_key].to_s
    env_key = LICENSE_PRICE_ENV_KEYS[plan_key]
    price_id = env_key.present? ? ENV[env_key].presence : nil
    source = params[:source].to_s.strip.presence || "web_checkout"

    if price_id.blank?
      render json: { error: "Unknown or unconfigured plan_key" }, status: :bad_request
      return
    end

    # Optional Pro-only extra communicator slots bundled with the license
    # (one-time, expiring with the license). Basic licenses don't offer extras.
    extra_communicators = Billing::ExtraCommunicators.clamp(params[:extra_communicators])
    extra_price_id = nil
    if extra_communicators.positive?
      if plan_key != "pro_5yr"
        render json: { error: "Extra communicators are only available on the Pro license" }, status: :bad_request
        return
      end
      extra_price_id = Billing::ExtraCommunicators.price_id("license")
      if extra_price_id.blank?
        render json: { error: "Extra communicators are not available" }, status: :bad_request
        return
      end
    end

    ensure_customer!

    monthly_credits = CreditService.monthly_credits_for(plan_key)

    line_items = [{ price: price_id, quantity: 1 }]
    line_items << { price: extra_price_id, quantity: extra_communicators } if extra_price_id

    # NOTE: `payment_method_collection` is only valid on subscription-mode
    # Checkout Sessions — Stripe rejects it on mode=payment ("You can only set
    # `payment_method_collection` if there are recurring prices"). Leaving it
    # off; mode=payment collects a payment method by default.
    #
    # allow_promotion_codes lets the October tranche promo (FOUNDING5, 20% off)
    # apply at checkout — the promo itself is created in the Stripe dashboard, no
    # code needed here.
    session = Stripe::Checkout::Session.create(
      mode: "payment",
      customer: current_user.stripe_customer_id,
      client_reference_id: current_user.id.to_s,
      line_items: line_items,
      success_url: "#{frontend_base_url}/billing/success?session_id={CHECKOUT_SESSION_ID}&type=license",
      cancel_url: "#{frontend_base_url}/pricing",
      allow_promotion_codes: true,
      metadata: {
        kind: "license",
        user_id: current_user.id,
        plan_type: plan_key,
        license_years: LICENSE_YEARS,
        monthly_credits: monthly_credits,
        extra_communicators: extra_communicators,
        source: source,
      },
    )
    # Record the picked plan so the checkout_completed analytics can name it,
    # mirroring the subscription path. Does NOT grant anything — the webhook is
    # the sole authority for plan + credits.
    current_user.update!(paid_plan_type: plan_key)

    PosthogService.capture_for_user(
      current_user,
      "checkout_started",
      properties: {
        plan: plan_key,
        kind: "license",
        license_years: LICENSE_YEARS,
        source: source,
      },
    )
    render json: { url: session.url }
  rescue Stripe::StripeError => e
    Rails.logger.error "[License] Stripe error creating license session: #{e.class} - #{e.message}"
    render json: { error: "Failed to create license session" }, status: :bad_request
  rescue StandardError => e
    Rails.logger.error "[License] Unexpected error creating license session: #{e.class} - #{e.message}"
    render json: { error: "Failed to create license session" }, status: :bad_request
  end

  # Best-effort fast-path the frontend calls on the Stripe success redirect to
  # reflect the new plan without waiting for the webhook. The Stripe webhook
  # remains the source of truth for plan + credits — this only mirrors what it
  # will set, and grants NOTHING for a checkout that didn't actually complete.
  def update_user_from_session
    session = Stripe::Checkout::Session.retrieve(params[:session_id].to_s)

    # Only the authenticated owner may reconcile from their own checkout —
    # don't let one user act on another's session.
    if session.metadata&.user_id.to_s != current_user.id.to_s
      render json: { error: "Session does not belong to this user" }, status: :forbidden
      return
    end

    # CRITICAL: only a COMPLETED checkout grants a plan. An abandoned/expired
    # session is "open"/"expired" — reflecting its plan_key would hand a paid
    # tier to someone who never paid. No-op (not an error) so the frontend can
    # retry while the webhook catches up.
    unless session.status == "complete"
      render json: { success: true, status: session.status }
      return
    end

    # 5-Year license fast-path (metadata.kind == "license"). Licenses are a
    # one-time payment with no subscription, so plan_and_status_from_session
    # (which reads session.subscription) doesn't apply. Reflect the plan +
    # expiry the webhook will set; grant NO credits (webhook authority).
    if (session.metadata&.kind).to_s == "license"
      license_plan = normalize_license_plan_key(session.metadata&.plan_type)
      if license_plan.present?
        current_user.plan_type = license_plan
        current_user.plan_status = "active"
        current_user.plan_expires_at ||= license_years_from_metadata(session.metadata).years.from_now
        current_user.setup_limits
        current_user.save!
        # Mirror any Pro-only extra-communicator slots the license bundled (the
        # webhook is still the authority; this only reflects it faster).
        extra = session.metadata&.extra_communicators.to_i
        current_user.apply_extra_communicator_slots!(extra) if license_plan == "pro_5yr" && extra.positive?
        MailchimpEventJob.perform_async(current_user.id, "sign_up")
      end
      render json: { success: true }
      return
    end

    plan_type, plan_status = plan_and_status_from_session(session)
    if plan_type.present?
      current_user.plan_type = plan_type
      current_user.plan_status = plan_status
      current_user.setup_limits
      current_user.save!
      MailchimpEventJob.perform_async(current_user.id, "sign_up")
    end
    render json: { success: true }
  rescue Stripe::StripeError, StandardError => e
    Rails.logger.error "Error updating user from session: #{e.class} - #{e.message}"
    render json: { error: "Failed to update user from session" }, status: :bad_request
  end

  private

  # Plan tier + status for a COMPLETED checkout. Prefers the real subscription
  # (status-correct: trialing vs active, plan from the price metadata) so a
  # no-card trial isn't recorded as "active" and clobbering the webhook's
  # "trialing"; falls back to the session's plan_key. Credits are NOT granted
  # here — the webhook (invoice.payment_succeeded / subscription.created) is the
  # sole credit-grant authority.
  def plan_and_status_from_session(session)
    plan_key = session.metadata&.plan_key
    status = "active"

    if session.subscription.present?
      sub = Stripe::Subscription.retrieve(session.subscription.to_s)
      status = %w[trialing active].include?(sub.status.to_s) ? sub.status.to_s : "active"
      price = sub.items&.data&.first&.price
      plan_key = (price&.metadata || {})["plan_type"].presence || plan_key
    end

    [normalize_plan_key(plan_key).presence, status]
  end

  # Only accept license plan_types we actually issue, so a tampered/misconfigured
  # session metadata can't reflect an arbitrary plan onto the user.
  def normalize_license_plan_key(plan_type)
    key = plan_type.to_s
    LICENSE_PRICE_ENV_KEYS.key?(key) ? key : nil
  end

  def license_years_from_metadata(metadata)
    years = metadata&.license_years.to_i
    years.positive? ? years : LICENSE_YEARS
  end

  def ensure_customer!
    current_user.ensure_stripe_customer!
  end

  # Base plan tier without the billing-cadence suffix ("pro_yearly" → "pro"),
  # so the `checkout_started` `plan` property matches the frontend + the
  # webhook's `subscription_started` shape (plan + separate billing_interval).
  def plan_base(plan_key)
    plan_key.to_s.sub(/_yearly\z/, "")
  end

  # "yearly" for the `_yearly` price keys, "monthly" otherwise. Mirrors
  # `billing_interval_from_price` in the webhook, but derived from the plan_key
  # we already have at session-create time (no Stripe round-trip).
  def billing_interval_for(plan_key)
    plan_key.to_s.end_with?("_yearly") ? "yearly" : "monthly"
  end

  # Prefer the request's Origin (then Referer) when it points at a trusted
  # host. This lets Netlify preview deploys, the production app, and local
  # dev all redirect back to themselves after Stripe Checkout without
  # needing the deploy URL baked into a server-side env var.
  #
  # Falls back to ENV["FRONT_END_URL"] when the request didn't supply a
  # recognized origin (e.g. server-to-server calls in tests, mis-set CORS).
  def frontend_base_url
    candidate = request.headers["Origin"].presence || request.headers["Referer"].presence

    if candidate.present?
      begin
        uri = URI.parse(candidate)
        host = uri.host.to_s.downcase
        if uri.scheme.in?(%w[http https]) && ALLOWED_FRONTEND_HOSTS.any? { |re| host.match?(re) }
          base = +"#{uri.scheme}://#{uri.host}"
          base << ":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)
          return base
        end
      rescue URI::InvalidURIError
        # fall through to env fallback
      end
    end

    ENV["FRONT_END_URL"].presence || "http://localhost:8100"
  end
end
