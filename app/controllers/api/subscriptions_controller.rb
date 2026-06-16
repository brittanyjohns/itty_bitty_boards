class API::SubscriptionsController < API::ApplicationController
  DOMAIN = ENV["FRONT_END_URL"] || "http://localhost:8100"
  PRO_PLAN_PRICE_ID = ENV["PRO_PLAN_PRICE_ID"]

  def index
    stripe_customer_id = current_user.stripe_customer_id
    @subscriptions = Stripe::Subscription.list({ customer: stripe_customer_id })
    render json: { subscriptions: @subscriptions, stripe_customer_id: stripe_customer_id }, status: 200
  end

  def billing_portal
    # Free accounts (mobile signups, legacy users) may not have a Stripe
    # customer yet — create one lazily so the portal works for everyone.
    customer_id = current_user.ensure_stripe_customer!
    portal_params = {
      customer: customer_id,
      return_url: "#{DOMAIN}/dashboard",
    }
    portal_params[:configuration] = ENV["STRIPE_PORTAL_CONFIG_ID"] if ENV["STRIPE_PORTAL_CONFIG_ID"].present?
    session = Stripe::BillingPortal::Session.create(portal_params)
    render json: { url: session&.url }, status: 200
  rescue Stripe::StripeError => e
    Rails.logger.error "billing_portal: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to create billing portal session" }, status: :bad_request
  end

  # Promo-aware one-click plan switch for EXISTING subscribers (issue #308).
  #
  # Free users get a discounted upgrade via a fresh Checkout session
  # (checkout_sessions_controller). Existing subscribers can't — a new
  # checkout on an active subscription would double-bill. Instead we open a
  # Stripe Customer-portal *deep link* (`flow_data.subscription_update_confirm`)
  # that pre-selects the target price and pre-applies the promotion code, so
  # Stripe renders its own confirm page (price change + discount + proration)
  # and we never mutate the subscription directly. The resulting
  # `customer.subscription.updated` webhook flows through `handle_subscription_upsert`
  # exactly like a manual portal switch — `Price.metadata["plan_type"]` drives
  # the new entitlements.
  #
  # POST /api/subscriptions/change_plan_portal_session
  #   params: plan_key (required), promo_code (optional)
  def change_plan_portal_session
    plan_key = params[:plan_key].to_s
    price_id = API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS[plan_key]

    if price_id.blank?
      render json: { error: "Unknown or unsupported plan" }, status: :unprocessable_entity
      return
    end

    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      # No Stripe customer means no subscription to update — these users
      # belong in checkout, not here.
      render json: { error: "No active subscription to change" }, status: :unprocessable_entity
      return
    end

    subscription = active_subscription_for(customer_id)
    if subscription.nil?
      render json: { error: "No active subscription to change" }, status: :unprocessable_entity
      return
    end

    item = subscription.items.data.first
    update_confirm = {
      subscription: subscription.id,
      items: [{ id: item.id, price: price_id, quantity: 1 }],
    }

    promo = resolve_promotion_code(params[:promo_code])
    update_confirm[:discounts] = [{ promotion_code: promo.id }] if promo.present?

    portal_params = {
      customer: customer_id,
      return_url: "#{DOMAIN}/dashboard",
      flow_data: {
        type: "subscription_update_confirm",
        subscription_update_confirm: update_confirm,
      },
    }
    portal_params[:configuration] = ENV["STRIPE_PORTAL_CONFIG_ID"] if ENV["STRIPE_PORTAL_CONFIG_ID"].present?

    session = Stripe::BillingPortal::Session.create(portal_params)
    render json: { url: session&.url }, status: 200
  rescue Stripe::StripeError => e
    Rails.logger.error "change_plan_portal_session: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to create plan change session" }, status: :bad_request
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

  private

  # The subscription a plan-change should act on: the customer's current
  # active/trialing/past_due subscription. Trialing is included so a no-card
  # reverse-trial user can switch to the founding-rate plan; Stripe's confirm
  # flow handles whether a payment method is required.
  def active_subscription_for(customer_id)
    Stripe::Subscription
      .list(customer: customer_id, status: "all", limit: 10)
      .data
      .find { |s| %w[active trialing past_due].include?(s.status) }
  end

  # Mirror the checkout controller's graceful promo lookup: resolve an active
  # promotion code to its Stripe object, or nil (silently skip) if blank/unknown.
  def resolve_promotion_code(raw_code)
    code = raw_code.to_s.strip
    return nil if code.blank?

    Stripe::PromotionCode.list(code: code, active: true, limit: 1).data.first
  end
end
