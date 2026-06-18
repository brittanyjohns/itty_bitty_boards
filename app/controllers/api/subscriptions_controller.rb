class API::SubscriptionsController < API::ApplicationController
  DOMAIN = ENV["FRONT_END_URL"] || "http://localhost:8100"
  PRO_PLAN_PRICE_ID = ENV["PRO_PLAN_PRICE_ID"]

  def index
    # Free/legacy/mobile accounts may not have a Stripe customer yet; create
    # one lazily so listing subscriptions never blows up on a nil customer.
    stripe_customer_id = current_user.ensure_stripe_customer!
    @subscriptions = Stripe::Subscription.list({ customer: stripe_customer_id })
    render json: { subscriptions: @subscriptions, stripe_customer_id: stripe_customer_id }, status: 200
  rescue Stripe::StripeError => e
    Rails.logger.error "subscriptions#index: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to load subscriptions" }, status: :bad_request
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
      render json: { error: "Unknown or unsupported plan" }, status: :unprocessable_content
      return
    end

    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      # No Stripe customer means no subscription to update — these users
      # belong in checkout, not here.
      render json: { error: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    subscription = active_subscription_for(customer_id)
    if subscription.nil?
      render json: { error: "No active subscription to change" }, status: :unprocessable_content
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

  # In-app proration preview for plan switches. Returns the exact amounts
  # Stripe will charge so the frontend can show a confirmation screen
  # without redirecting to the portal.
  #
  # POST /api/subscriptions/preview_plan_change
  #   params: plan_key (required), promo_code (optional)
  def preview_plan_change
    plan_key = params[:plan_key].to_s
    price_id = API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS[plan_key]

    if price_id.blank?
      render json: { error: "Unknown or unsupported plan" }, status: :unprocessable_content
      return
    end

    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      render json: { error: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    subscription = active_subscription_for(customer_id)
    if subscription.nil?
      render json: { error: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    current_price = subscription.items.data.first.price
    if current_price.id == price_id
      render json: { error: "Already on this plan" }, status: :unprocessable_content
      return
    end

    item = subscription.items.data.first
    details = {
      items: [{ id: item.id, price: price_id }],
      proration_behavior: "create_prorations",
    }

    promo = resolve_promotion_code(params[:promo_code])
    if promo.present?
      details[:discounts] = [{ promotion_code: promo.id }]
    end

    invoice_params = {
      customer: customer_id,
      subscription: subscription.id,
      subscription_details: details,
    }

    upcoming = Stripe::Invoice.upcoming(invoice_params)
    new_price = Stripe::Price.retrieve(price_id)

    render json: {
      current_plan: current_user.plan_type,
      new_plan: new_price.metadata["plan_type"] || plan_key.sub(/_yearly$/, ""),
      proration_amount_cents: upcoming.amount_due,
      new_recurring_amount_cents: new_price.unit_amount,
      billing_interval: new_price.recurring&.interval == "year" ? "yearly" : "monthly",
      next_billing_date: Time.at(subscription.current_period_end).iso8601,
      discount: promo.present? ? { code: params[:promo_code].to_s.strip, percent_off: promo.coupon&.percent_off, amount_off: promo.coupon&.amount_off } : nil,
      currency: upcoming.currency,
    }, status: :ok
  rescue Stripe::StripeError => e
    Rails.logger.error "preview_plan_change: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to preview plan change" }, status: :bad_request
  end

  # In-app plan switch — updates the subscription directly via the Stripe
  # API, no portal redirect. The resulting customer.subscription.updated
  # webhook flows through handle_subscription_upsert unchanged.
  #
  # POST /api/subscriptions/change_plan
  #   params: plan_key (required), promo_code (optional)
  def change_plan
    plan_key = params[:plan_key].to_s
    price_id = API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS[plan_key]

    if price_id.blank?
      render json: { error: "Unknown or unsupported plan" }, status: :unprocessable_content
      return
    end

    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      render json: { error: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    subscription = active_subscription_for(customer_id)
    if subscription.nil?
      render json: { error: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    current_price = subscription.items.data.first.price
    if current_price.id == price_id
      render json: { error: "Already on this plan" }, status: :unprocessable_content
      return
    end

    item = subscription.items.data.first
    update_params = {
      items: [{ id: item.id, price: price_id }],
      proration_behavior: "create_prorations",
    }

    promo = resolve_promotion_code(params[:promo_code])
    if promo.present?
      update_params[:discounts] = [{ promotion_code: promo.id }]
    end

    updated_sub = Stripe::Subscription.update(subscription.id, update_params)
    new_price_obj = updated_sub.items.data.first.price

    render json: {
      plan: new_price_obj.metadata["plan_type"] || plan_key.sub(/_yearly$/, ""),
      status: updated_sub.status,
      billing_interval: new_price_obj.recurring&.interval == "year" ? "yearly" : "monthly",
      current_period_end: Time.at(updated_sub.current_period_end).iso8601,
    }, status: :ok
  rescue Stripe::CardError => e
    Rails.logger.error "change_plan card error: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "payment_failed", message: "Your payment method was declined. Please update it and try again." }, status: :payment_required
  rescue Stripe::StripeError => e
    Rails.logger.error "change_plan: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to change plan" }, status: :bad_request
  end

  def create_customer_session
    customer_id = current_user.ensure_stripe_customer!
    customer_session =
      Stripe::CustomerSession.create({
        customer: customer_id,
        components: { pricing_table: { enabled: true } },
      })
    render json: { client_secret: customer_session.client_secret }, status: 200
  rescue Stripe::StripeError => e
    Rails.logger.error "subscriptions#create_customer_session: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to create customer session" }, status: :bad_request
  end

  def list
    customer_id = current_user.ensure_stripe_customer!
    subscriptions_result = Stripe::Subscription.list({ customer: customer_id })
    subscriptions = subscriptions_result.data
    has_more = subscriptions_result.has_more
    render json: { subscriptions: subscriptions, has_more: has_more }, status: 200
  rescue Stripe::StripeError => e
    Rails.logger.error "subscriptions#list: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to load subscriptions" }, status: :bad_request
  end

  def add_item
    lookup_key = params[:lookup_key]
    price_list = Stripe::Price.list({ lookup_keys: [lookup_key] })
    price = price_list.data.first
    price_id = price.id
    customer_id = current_user.ensure_stripe_customer!
    subscriptions_result = Stripe::Subscription.list({ customer: customer_id })

    subscriptions = subscriptions_result["data"]
    subscription = subscriptions.first
    # A customer with no subscription (e.g. a free user) has nothing to add to.
    if subscription.nil?
      render json: { error: "No active subscription to modify" }, status: :unprocessable_content
      return
    end
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
  rescue Stripe::StripeError => e
    Rails.logger.error "subscriptions#add_item: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to update subscription" }, status: :bad_request
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
