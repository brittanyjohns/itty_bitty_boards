# app/controllers/api/stripe/checkout_sessions_controller.rb
class API::Stripe::CheckoutSessionsController < API::ApplicationController
  before_action :authenticate_token!

  PLAN_PRICE_IDS = {
    "free" => nil, # you might not need checkout for free
    "myspeak" => ENV.fetch("STRIPE_PRICE_MYSPEAK", nil),
    "basic" => ENV.fetch("STRIPE_PRICE_BASIC", nil),
    "pro" => ENV.fetch("STRIPE_PRICE_PRO", nil),
    "myspeak_yearly" => ENV.fetch("STRIPE_PRICE_MYSPEAK_YEAR", nil),
    "basic_yearly" => ENV.fetch("STRIPE_PRICE_BASIC_YEAR", nil),
    "pro_yearly" => ENV.fetch("STRIPE_PRICE_PRO_YEAR", nil),
  }.freeze

  def create
    plan_key = params[:plan_key].to_s
    price_id = PLAN_PRICE_IDS[plan_key]
    Rails.logger.info "Creating checkout session for user #{current_user.id} with plan_key=#{plan_key}, price_id=#{price_id}"

    if plan_key == "free" || price_id.blank?
      # Staying on free: mark user as free and send them into app
      Rails.logger.info "User #{current_user.id} selecting free plan; skipping checkout."
      current_user.update!(
        plan_type: "free",
        plan_status: "active",
      )
      render json: { url: "#{frontend_base_url}/home" } and return
    end

    unless current_user.stripe_customer_id.present?
      # In your signup flow you should already create the customer;
      # this is just a safety net.
      customer = Stripe::Customer.create(
        email: current_user.email,
      )
      current_user.update!(stripe_customer_id: customer.id)
    end

    session = Stripe::Checkout::Session.create(
      mode: "subscription",
      customer: current_user.stripe_customer_id,
      line_items: [
        {
          price: price_id,
          quantity: 1,
        },
      ],
      success_url: "#{frontend_base_url}/billing/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{frontend_base_url}/onboarding",
      metadata: {
        user_id: current_user.id,
      },
    )

    render json: { url: session.url }
  rescue StandardError => e
    Rails.logger.error "Error creating checkout session: #{e.class} - #{e.message}"
    render json: { error: "Failed to create checkout session" }, status: :bad_request
  end

  private

  def frontend_base_url
    ENV["FRONTEND_BASE_URL"] || "http://localhost:8100"
  end
end
