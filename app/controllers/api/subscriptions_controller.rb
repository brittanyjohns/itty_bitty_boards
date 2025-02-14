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

  def create_customer_session
    customer_id = current_user.stripe_customer_id
    customer_session =
      Stripe::CustomerSession.create({
        customer: customer_id,
        components: { pricing_table: { enabled: true } },
      })
    render json: { client_secret: customer_session.client_secret }, status: 200
  end

  def list
    customer_id = current_user.stripe_customer_id
    subscriptions_result = Stripe::Subscription.list({ customer: customer_id })
    subscriptions = subscriptions_result.data
    has_more = subscriptions_result.has_more
    render json: { subscriptions: subscriptions, has_more: has_more }, status: 200
  end

  def add_item
    lookup_key = params[:lookup_key]
    price_list = Stripe::Price.list({ lookup_keys: [lookup_key] })
    price = price_list.data.first
    price_id = price.id
    customer_id = current_user.stripe_customer_id
    subscriptions_result = Stripe::Subscription.list({ customer: customer_id })

    subscriptions = subscriptions_result["data"]
    subscription = subscriptions.first
    existing_items = subscription["items"]["data"]

    existing_item = existing_items.find { |item| item["price"]["id"] == price_id }
    if existing_item
      if lookup_key == "basic_extra_comm" && current_user.basic? && existing_item["quantity"] >= 1
        render json: { error: "You can only have one extra communicator with the basic plan" }, status: 400
        return
      end
      item_id = existing_item[:sub_item_id]
      subscription = Stripe::SubscriptionItem.update(item_id, { quantity: existing_item[:quantity] + 1 })
    else
      subscription = Stripe::Subscription.update(subscription["id"], { items: [{ price: price_id }] })
    end

    render json: { subscription: subscription }, status: 200
  end
end
