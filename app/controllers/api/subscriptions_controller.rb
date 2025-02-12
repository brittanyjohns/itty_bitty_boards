class API::SubscriptionsController < API::ApplicationController
  DOMAIN = ENV["FRONT_END_DOMAIN"] || "http://localhost:8100"
  PRO_PLAN_PRICE_ID = ENV["PRO_PLAN_PRICE_ID"]

  def index
    @subscriptions = current_user.subscriptions.distinct
    render json: { subscriptions: @subscriptions }, status: 200
  end

  def billing_portal
    # Create a billing portal
    session = Stripe::BillingPortal::Session.create({
      customer: current_user.stripe_customer_id,
      return_url: "#{DOMAIN}/dashboard",
    })
    render json: { url: session.url }, status: 200
  end
end
