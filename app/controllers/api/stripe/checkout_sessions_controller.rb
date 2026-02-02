# app/controllers/api/stripe/checkout_sessions_controller.rb
class API::Stripe::CheckoutSessionsController < API::ApplicationController
  before_action :authenticate_token!

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

  def create
    plan_key = params[:plan_key].to_s
    price_id = PLAN_PRICE_IDS[plan_key]
    Rails.logger.debug "Creating checkout session for plan_key: #{plan_key}, price_id: #{price_id}"

    if plan_key == "free" || price_id.blank?
      current_user.update!(plan_type: "free", plan_status: "active")
      Rails.logger.error "User #{current_user.id} is on the free plan or price_id is blank"
      render json: { url: "#{frontend_base_url}/home" } and return
    end
    is_partner = plan_key == "partner_pro"

    ensure_customer!

    trial_days = 14
    cancel_url = is_partner ? "#{frontend_base_url}/onboarding/partner" : "#{frontend_base_url}/onboarding"

    session_params = {
      mode: "subscription",
      customer: current_user.stripe_customer_id,
      line_items: [{ price: price_id, quantity: 1 }],
      success_url: "#{frontend_base_url}/billing/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: cancel_url,
      metadata: { user_id: current_user.id, plan_key: plan_key },
      payment_method_collection: "if_required",
      cancel_url: cancel_url,
    }
    if plan_key == "partner_pro"
      promo_code_str = ENV["STRIPE_PARTNER_PILOT_PROMO"] || "PARTNERPILOT26"
      promo = Stripe::PromotionCode.list(
        code: promo_code_str,
        active: true,
        limit: 1,
      ).data.first

      if promo.nil?
        raise "Invalid promo code"
      end
      session_params[:discounts] = [
        { promotion_code: promo.id },
      ]
    else
      session_params[:allow_promotion_codes] = true
      session_params[:subscription_data] = {
        trial_period_days: trial_days,
      }
    end

    session = Stripe::Checkout::Session.create(session_params)
    render json: { url: session.url }
  rescue StandardError => e
    Rails.logger.error "Error creating checkout session: #{e.class} - #{e.message}"
    render json: { error: "Failed to create checkout session" }, status: :bad_request
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

  def frontend_base_url
    ENV["FRONT_END_URL"] || "http://localhost:8100"
  end
end
