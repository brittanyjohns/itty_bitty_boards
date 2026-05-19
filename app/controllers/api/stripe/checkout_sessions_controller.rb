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
    "myspeak" => ENV.fetch("STRIPE_PRICE_MYSPEAK", nil),
    "basic" => ENV.fetch("STRIPE_PRICE_BASIC", nil),
    "pro" => ENV.fetch("STRIPE_PRICE_PRO", nil),
    "myspeak_yearly" => ENV.fetch("STRIPE_PRICE_MYSPEAK_YEAR", nil),
    "basic_yearly" => ENV.fetch("STRIPE_PRICE_BASIC_YEAR", nil),
    "pro_yearly" => ENV.fetch("STRIPE_PRICE_PRO_YEAR", nil),
    "partner_pro" => ENV.fetch("STRIPE_PRICE_PARTNER_PRO", nil),
  }.freeze

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

    if plan_key == "free" || price_id.blank?
      current_user.update!(plan_type: "free", plan_status: "active")
      render json: { url: "#{frontend_base_url}/home" } and return
    end
    is_partner = plan_key == "partner_pro"

    payment_method_collection = ENV["STRIPE_PAYMENT_METHOD_COLLECTION"] == "always" ? "always" : "if_required"
    ensure_customer!

    trial_days = 14
    cancel_url = "#{frontend_base_url}/onboarding"
    if is_partner
      cancel_url = "#{frontend_base_url}/onboarding/partner"
    elsif plan_key.include?("myspeak")
      cancel_url = "#{frontend_base_url}/onboarding/myspeak"
    end

    bypass_payment_required = params[:bypass_payment_required] == "true" || promo_code&.upcase == NO_CC_KEY

    if bypass_payment_required
      payment_method_collection = "if_required"
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
      line_items: [{ price: price_id, quantity: 1 }],
      success_url: "#{frontend_base_url}/billing/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: cancel_url,
      metadata: { user_id: current_user.id, plan_key: plan_key },
      payment_method_collection: payment_method_collection,
    }

    if promo.present?
      session_params[:discounts] = [
        { promotion_code: promo.id },
      ]
    else
      session_params[:allow_promotion_codes] = true
    end
    session_params[:subscription_data] = {
      trial_period_days: trial_days,
    }

    session = Stripe::Checkout::Session.create(session_params)
    current_user.update!(paid_plan_type: plan_key)
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
      line_items: [{ price: price_id, quantity: quantity }],
      success_url: "#{frontend_base_url}/account/billing/topup/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{frontend_base_url}/account/billing",
      allow_promotion_codes: true,
      metadata: {
        kind: "topup",
        user_id: current_user.id,
        pack_key: pack_key,
        credit_amount: credit_amount * quantity,
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

  def update_user_from_session
    session_id = params[:session_id].to_s
    session = Stripe::Checkout::Session.retrieve(session_id)
    user_id = session.metadata.user_id
    plan_key = session.metadata.plan_key
    user = User.find_by(id: user_id)
    if user.nil?
      render json: { error: "User not found" }, status: :not_found
      return
    end
    normalized_plan_key = normalize_plan_key(plan_key)
    user.plan_type = normalized_plan_key
    user.plan_status = "active"
    user.setup_limits
    user.save!
    MailchimpEventJob.perform_async(user.id, "sign_up")
    render json: { success: true }
  rescue StandardError => e
    Rails.logger.error "Error updating user from session: #{e.class} - #{e.message}"
    render json: { error: "Failed to update user from session" }, status: :bad_request
  end

  private

  def ensure_customer!
    return if current_user.stripe_customer_id.present?

    customer = Stripe::Customer.create(email: current_user.email)
    current_user.update!(stripe_customer_id: customer.id)
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
