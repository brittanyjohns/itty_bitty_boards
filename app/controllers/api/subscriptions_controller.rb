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

  # Flows the client may request. Allow-listed rather than passed through so a
  # client can't drive arbitrary Stripe portal flows.
  PORTAL_FLOWS = %w[payment_method_update].freeze

  def billing_portal
    # Free accounts (mobile signups, legacy users) may not have a Stripe
    # customer yet — create one lazily so the portal works for everyone.
    customer_id = current_user.ensure_stripe_customer!
    portal_params = {
      customer: customer_id,
      return_url: "#{DOMAIN}/dashboard",
    }
    # Focused "add a card" flow for the trial banner's payment-method CTA.
    # Without it the portal opens on its home screen and a trialist with no
    # card has to hunt for the payment-method section.
    if PORTAL_FLOWS.include?(params[:flow].to_s)
      portal_params[:flow_data] = { type: params[:flow].to_s }
    end
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
      render json: { error: "unknown_plan", message: "Unknown or unsupported plan" }, status: :unprocessable_content
      return
    end

    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      render json: { error: "no_subscription", message: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    subscription = active_subscription_for(customer_id)
    item = subscription && plan_item_for(subscription)
    if item.nil?
      render json: { error: "no_subscription", message: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    if item.price.id == price_id
      render json: { error: "already_on_plan", message: "You're already on this plan." }, status: :unprocessable_content
      return
    end

    promo = resolve_promotion_code(params[:promo_code])
    trialing = subscription.status == "trialing"

    # Stripe does not prorate during a trial -- the switch takes effect now and
    # the new price is billed at trial end -- so nothing is due today and there
    # is nothing to ask Stripe for. Asking anyway is worse than redundant: for a
    # no-card reverse trial the upcoming-invoice preview is REFUSED outright
    # ("The subscription will cancel at the end of the trial ...
    # trial_settings[end_behavior][missing_payment_method] is set to `cancel`"),
    # and that describes every trial we start (Billing::StartTrial). That
    # refusal is why a trialist could not upgrade at all: it landed in the
    # rescue below and the modal had nothing to show but an error.
    upcoming = trialing ? nil : upcoming_invoice_for(customer_id, subscription, item, price_id, promo)

    new_price = Stripe::Price.retrieve(price_id)
    proration_cents = trialing ? 0 : upcoming&.amount_due
    trial_end = subscription.trial_end if subscription.respond_to?(:trial_end)

    # Warn up-front when this switch bills the customer today but they have no
    # payment method on file -- so the modal prompts them to the billing portal
    # before they hit a Confirm that would only fail. Credit-only downgrades
    # (amount_due <= 0) don't need a card, so they aren't flagged. Neither is a
    # trialist: nothing is charged until the trial ends, and demanding a card
    # mid-trial is the exact friction the no-card trial exists to avoid.
    payment_method_required =
      !trialing &&
      proration_cents.to_i > 0 &&
      !customer_has_payment_method?(customer_id, subscription)

    render json: {
      current_plan: current_user.plan_type,
      new_plan: new_price.metadata["plan_type"] || plan_key.sub(/_yearly$/, ""),
      proration_amount_cents: proration_cents,
      new_recurring_amount_cents: new_price.unit_amount,
      billing_interval: new_price.recurring&.interval == "year" ? "yearly" : "monthly",
      next_billing_date: epoch_iso8601(trialing ? (trial_end || subscription.current_period_end) : subscription.current_period_end),
      discount: promo.present? ? { code: params[:promo_code].to_s.strip, percent_off: promo.coupon&.percent_off, amount_off: promo.coupon&.amount_off } : nil,
      currency: upcoming&.currency || new_price.currency,
      payment_method_required: payment_method_required,
      trialing: trialing,
      trial_end: epoch_iso8601(trial_end),
      # True when we could not price the switch. The frontend then drops its
      # "Due today" line and still offers Confirm -- Stripe prices the change
      # for real when it happens, and a modal that can only say no is worse
      # than one that says "the exact amount will be on your receipt".
      preview_unavailable: !trialing && upcoming.nil?,
    }, status: :ok
  rescue Stripe::StripeError => e
    report_stripe_error("preview_plan_change", e, plan_key: plan_key)
    render json: { error: "preview_failed", message: "Failed to preview plan change" }, status: :bad_request
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
      render json: { error: "unknown_plan", message: "Unknown or unsupported plan" }, status: :unprocessable_content
      return
    end

    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      render json: { error: "no_subscription", message: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    subscription = active_subscription_for(customer_id)
    item = subscription && plan_item_for(subscription)
    if item.nil?
      render json: { error: "no_subscription", message: "No active subscription to change" }, status: :unprocessable_content
      return
    end

    if item.price.id == price_id
      render json: { error: "already_on_plan", message: "You're already on this plan." }, status: :unprocessable_content
      return
    end

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
      current_period_end: epoch_iso8601(updated_sub.current_period_end),
    }, status: :ok
  rescue Stripe::CardError => e
    report_stripe_error("change_plan card error", e, plan_key: plan_key)
    render json: { error: "payment_failed", message: "Your payment method was declined. Please update it and try again." }, status: :payment_required
  rescue Stripe::InvalidRequestError => e
    # An upgrade (or interval switch) that bills immediately fails when the
    # customer has no payment method on file — a common case for no-card
    # reverse-trial users. Surface a distinct, actionable code so the frontend
    # can route them to the billing portal instead of showing a dead-end error.
    if missing_payment_method_error?(e)
      Rails.logger.warn "change_plan no payment method: #{e.message} (user #{current_user.id})"
      render json: { error: "payment_method_required", message: "You don't have a payment method on file. Add one in the billing portal, then try changing your plan again." }, status: :payment_required
    else
      report_stripe_error("change_plan", e, plan_key: plan_key)
      render json: { error: "change_failed", message: "Failed to change plan" }, status: :bad_request
    end
  rescue Stripe::StripeError => e
    report_stripe_error("change_plan", e, plan_key: plan_key)
    render json: { error: "change_failed", message: "Failed to change plan" }, status: :bad_request
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

  # POST /api/subscriptions/communicator_addon  { quantity: N }
  #
  # Set the Pro extra-communicator add-on to EXACTLY N recurring slots on the
  # user's active subscription (0 removes it). Pro-only; the billing interval
  # (monthly/yearly) matches the user's current plan price. Stripe's own
  # proration applies. The resulting customer.subscription.updated webhook
  # re-derives entitlements; we also sync immediately so this response reflects
  # the new slot limit without waiting for the webhook. See
  # Billing::ExtraCommunicators.
  def communicator_addon
    quantity = Billing::ExtraCommunicators.clamp(params[:quantity])

    unless current_user.pro?
      render json: { error: "Extra communicators are available on the Pro plan" }, status: :forbidden
      return
    end

    customer_id = current_user.ensure_stripe_customer!
    subscription = active_subscription_for(customer_id)
    if subscription.nil?
      render json: { error: "No active subscription to modify" }, status: :unprocessable_content
      return
    end

    interval = billing_interval_for_subscription(subscription)
    price_id = Billing::ExtraCommunicators.recurring_price_id(interval)
    if price_id.blank?
      render json: { error: "Extra communicators are not available" }, status: :unprocessable_content
      return
    end

    existing = subscription.items.data.find { |item| Billing::ExtraCommunicators.extra_comm_item?(item) }

    if quantity.zero?
      Stripe::SubscriptionItem.delete(existing.id) if existing
    elsif existing
      Stripe::SubscriptionItem.update(existing.id, { quantity: quantity })
    else
      Stripe::Subscription.update(subscription.id, { items: [{ price: price_id, quantity: quantity }] })
    end

    current_user.apply_extra_communicator_slots!(quantity)

    render json: {
      quantity: quantity,
      communicator_slot_limit: Permissions::CommunicatorLimits.slot_limit_for(current_user.settings || {}),
    }, status: 200
  rescue Stripe::StripeError => e
    Rails.logger.error "subscriptions#communicator_addon: #{e.class} - #{e.message} (user #{current_user.id})"
    render json: { error: "Failed to update subscription" }, status: :bad_request
  end

  private

  # "yearly" when the plan (non-add-on) item bills annually, else "monthly".
  def billing_interval_for_subscription(subscription)
    interval = plan_item_for(subscription)&.price&.recurring&.interval
    interval == "year" ? "yearly" : "monthly"
  end

  # The subscription item a plan change should reprice. NEVER items.data.first:
  # a Pro subscriber carrying the extra-communicator add-on can have the add-on
  # sitting first, and repricing that item swaps the add-on for the plan.
  def plan_item_for(subscription)
    subscription.items.data.find { |item| !Billing::ExtraCommunicators.extra_comm_item?(item) }
  end

  # The upcoming-invoice preview for a plan switch, or nil when Stripe declines
  # to produce one. Rescued locally rather than at the action level on purpose:
  # this call is the only part of the payload that needs it, and the plan name,
  # recurring price, interval and period end all come from elsewhere -- so a
  # refusal degrades the confirm screen instead of dead-ending it.
  def upcoming_invoice_for(customer_id, subscription, item, price_id, promo)
    details = {
      items: [{ id: item.id, price: price_id }],
      proration_behavior: "create_prorations",
    }
    details[:discounts] = [{ promotion_code: promo.id }] if promo.present?

    Stripe::Invoice.upcoming(
      customer: customer_id,
      subscription: subscription.id,
      subscription_details: details,
    )
  rescue Stripe::StripeError => e
    report_stripe_error("preview_plan_change upcoming invoice", e)
    nil
  end

  # Stripe hands epoch seconds, and a nil one used to raise TypeError out of
  # Time.at -- past the Stripe::StripeError rescues, so it 500'd with an HTML
  # body that the client then failed to parse as JSON. Omit the date instead.
  def epoch_iso8601(seconds)
    return nil if seconds.nil?

    Time.at(seconds).iso8601
  rescue TypeError, RangeError
    nil
  end

  # One structured line per Stripe failure, plus an APM error event. The message
  # alone does not diagnose these: code/param/request_id are what name which
  # call failed and why. And because these errors are rescued and rendered,
  # AppSignal otherwise sees an ordinary 400 and never alerts -- which is how
  # the trial preview stayed broken without surfacing anywhere.
  def report_stripe_error(context, error, **extra)
    details = {
      class: error.class.name,
      code: error.try(:code),
      param: error.try(:param),
      status: error.try(:http_status),
      request_id: error.try(:request_id),
      user: current_user&.id,
    }.merge(extra).compact.map { |k, v| "#{k}=#{v}" }.join(" ")

    Rails.logger.error "#{context}: #{error.message} (#{details})"
    Appsignal.report_error(error) if defined?(Appsignal) && Appsignal.respond_to?(:report_error)
  end

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

  # Does the customer have a usable payment method for an immediate charge?
  # Delegates the actual lookup (subscription default -> customer
  # invoice_settings default -> legacy default_source) to the shared
  # Billing::PaymentMethods, also used by
  # WebhooksController#payment_method_on_file?. On any Stripe error we assume
  # "yes" so we never block a plan change on an inconclusive lookup — the
  # actual change attempt surfaces the real error reactively. This rescue is
  # deliberately kept local rather than folded into the shared lookup — see
  # that module's comment for why the two callers' fallbacks must stay
  # independent.
  def customer_has_payment_method?(customer_id, subscription = nil)
    Billing::PaymentMethods.on_file?(customer_id, subscription: subscription)
  rescue Stripe::StripeError => e
    Rails.logger.warn "customer_has_payment_method? lookup failed: #{e.message} (user #{current_user.id})"
    true
  end

  # A Stripe::InvalidRequestError raised because the customer has no payment
  # method on file (e.g. updating a no-card subscription to a plan that bills
  # immediately). Stripe doesn't expose a stable code for this, so match the
  # message — the only signal it gives.
  def missing_payment_method_error?(error)
    message = error.message.to_s.downcase
    message.include?("no attached payment") ||
      message.include?("payment source") ||
      message.include?("default payment method") ||
      message.include?("no payment method")
  end
end
