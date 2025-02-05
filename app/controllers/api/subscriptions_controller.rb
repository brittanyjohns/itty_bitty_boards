class API::SubscriptionsController < API::ApplicationController
  DOMAIN = ENV["DOMAIN"] || "http://localhost:8100"
  PRO_PLAN_PRICE_ID = ENV["PRO_PLAN_PRICE_ID"]

  def index
    @subscriptions = current_user.subscriptions.distinct
    render json: { subscriptions: @subscriptions }, status: 200
  end

  # def create_subscription
  #   # Create a new subscription
  #   @stripe_customer_id = current_user.stripe_customer_id
  #   subscription = Stripe::Subscription.create({
  #     customer: @stripe_customer_id,
  #     items: [{ price: PRO_PLAN_PRICE_ID }],
  #     payment_behavior: "default_incomplete",
  #     expand: ["latest_invoice.payment_intent"],
  #   })
  #   render json: { id: subscription.id, clientSecret: subscription.latest_invoice.payment_intent.client_secret }, status: 200
  # end

  # def cancel_subscription
  #   # Cancel a subscription
  #   subscription_id = params[:subscription_id]
  #   canceled_subscription = Stripe::Subscription.cancel(subscription_id)
  #   puts "Canceled subscription: #{canceled_subscription}"
  #   recorded_subscription = Subscription.find_by(stripe_subscription_id: subscription_id)
  #   if recorded_subscription.cancel!
  #     render json: { subscription: canceled_subscription }, status: 200
  #   else
  #     render json: { error: "Could not cancel subscription" }, status: 400
  #   end
  # end

  # def update_subscription
  #   # Update a subscription
  #   subscription_id = params[:subscription_id]
  #   subscription = Stripe::Subscription.update(subscription_id, {
  #     items: [{
  #       id: subscription.items.data[0].id,
  #       price: PRO_PLAN_PRICE_ID,
  #     }],
  #   })
  #   render json: { subscription: subscription }, status: 200
  # end

  # def invoice_preview
  #   # Preview an invoice
  #   customer_id = current_user.stripe_customer_id
  #   subscription_id = params[:subscription_id]
  #   subscription = Stripe::Subscription.retrieve(subscription_id)
  #   invoice = Stripe::Invoice.upcoming({
  #     customer: customer_id,
  #     subscription: subscription_id,
  #     subscription_items: [{
  #       id: subscription.items.data[0].id,
  #       price: PRO_PLAN_PRICE_ID,
  #     }],
  #   })
  #   render json: { invoice: invoice }, status: 200
  # end

  # def create_customer
  #   # Create a new customer
  #   price_id = PRO_PLAN_PRICE_ID
  #   customer = Stripe::Customer.create({
  #     email: current_user.email,
  #     name: current_user.name,
  #   })
  #   current_user.stripe_customer_id = customer.id
  #   if current_user.save
  #     render json: { id: customer.id }, status: 200
  #   else
  #     render json: { error: "Could not save customer" }, status: 400
  #   end
  # end

  # def success
  #   # Subscription was successful
  #   puts "Subscription successful"
  #   render json: { success: true }, status: 200
  # end

  def billing_portal
    # Create a billing portal
    session = Stripe::BillingPortal::Session.create({
      customer: current_user.stripe_customer_id,
      return_url: "http://localhost:8100/dashboard",
    })
    render json: { url: session.url }, status: 200
  end
end
