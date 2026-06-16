# frozen_string_literal: true

class API::WebhooksController < API::ApplicationController
  skip_before_action :authenticate_token!, only: :webhooks
  protect_from_forgery except: :webhooks if respond_to?(:protect_from_forgery)

  def webhooks
    payload = request.body.read
    sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
    result = { success: true }
    begin
      event = Stripe::Webhook.construct_event(
        payload,
        sig_header,
        ENV.fetch("STRIPE_WEBHOOK_SECRET")
      )
    rescue JSON::ParserError => e
      Rails.logger.error "[StripeWebhook] JSON parse error: #{e.message}"
      return render json: { error: "Invalid payload" }, status: :bad_request
    rescue Stripe::SignatureVerificationError => e
      Rails.logger.error "[StripeWebhook] Signature error: #{e.message}"
      return render json: { error: "Invalid signature" }, status: :bad_request
    end

    Rails.logger.info "[StripeWebhook] Received event #{event.id} (#{event.type})"

    # Idempotency gate. Stripe resends the same event id on delivery retries and
    # dashboard replays. Credit grants are already deduped on stripe_event_id,
    # but the non-credit handlers (apply_free_plan on delete/pause, past_due on
    # payment_failed) have no such guard and re-running them pollutes the credit
    # ledger with repeated expire/grant rows. This extends idempotency to the
    # whole handler, mirroring the RevenueCat processor. We record the event only
    # AFTER a clean run (see end of method), so a mid-handler crash still returns
    # a 4xx and lets Stripe retry the delivery.
    if ProcessedWebhookEvent.exists?(provider: STRIPE_PROVIDER, event_id: event.id)
      Rails.logger.info "[StripeWebhook] event #{event.id} already processed; skipping"
      return render json: { success: true, status: "already_processed" }
    end

    case event.type
    when "customer.created"
      handle_customer_created(event.data.object)
    when "checkout.session.completed"
      session_obj = event.data.object
      if (session_obj.metadata || {})["kind"] == "topup"
        handled = handle_topup_completed(session_obj, event.id)
        result = { error: "topup_not_credited" } unless handled
      else
        user = handle_checkout_completed(session_obj)
        unless user
          Rails.logger.error "[StripeWebhook] checkout.session.completed: no user found for session #{session_obj.id}"
          result = { error: "no_user_found" }
        end
      end
    when "customer.subscription.created", "customer.subscription.updated"
      handle_subscription_upsert(event.data.object)
      # First-period credit grant for trial users — paid users get credits
      # via invoice.payment_succeeded below, but trials have no invoice yet.
      if event.type == "customer.subscription.created"
        handle_trial_credit_grant(event.data.object, event.id)
        handle_trial_started_analytics(event.data.object)
      end
    when "customer.subscription.trial_will_end"
      handle_trial_will_end(event.data.object)
    when "customer.subscription.deleted"
      handle_subscription_deleted(event.data.object)
    when "customer.subscription.paused"
      handle_subscription_paused(event.data.object)
    when "invoice.payment_succeeded"
      handle_invoice_payment_succeeded(event.data.object, event.id)
    when "invoice.payment_failed"
      handle_invoice_payment_failed(event.data.object)
    else
      Rails.logger.info "[StripeWebhook] Ignoring unhandled event type=#{event.type}"
    end

    record_processed_event!(event)
    render json: result
  rescue => e
    Rails.logger.error "[StripeWebhook] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
    render json: { error: "server_error" }, status: :bad_request
  end

  private

  STRIPE_PROVIDER = "stripe"

  # Record a fully-processed event for idempotency + audit. Called only after the
  # handler runs without raising. Swallows the unique-index race from a
  # concurrent duplicate delivery — either way the event is processed.
  def record_processed_event!(event)
    ProcessedWebhookEvent.create!(
      provider: STRIPE_PROVIDER,
      event_id: event.id,
      event_type: event.type,
      processed_at: Time.current,
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    Rails.logger.info "[StripeWebhook] event #{event.id} recorded concurrently; skipping duplicate insert"
  end

  # Terminal Stripe subscription statuses that mean "the trial/subscription
  # ended without a successful payment." A no-card reverse trial (issue #264)
  # lands here when it lapses. `past_due` is deliberately NOT in this list — a
  # real payer's failed renewal stays in dunning (see handle_invoice_payment_failed).
  TRIAL_LAPSED_STATUSES = %w[unpaid incomplete_expired].freeze

  # ========== Event handlers ==========

  # Stripe fires this ~3 days before a trial ends. No state change here — the
  # actual downgrade happens when the trial truly ends (subscription canceled
  # via the `missing_payment_method: cancel` end_behavior, or upsert sees a
  # terminal status). We record an analytics event so the trial-ending upgrade
  # nudge (frontend #293) is measurable.
  def handle_trial_will_end(subscription)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook] trial_will_end: no user for customer #{subscription.customer}"
      return
    end

    trial_end = subscription.respond_to?(:trial_end) ? subscription.trial_end : nil
    AnalyticsEvent.track(
      "trial_will_end",
      user_id: user.id,
      metadata: {
        plan_type: user.plan_type,
        subscription_id: subscription.id,
        trial_end: trial_end,
      },
    )

    # Mailchimp "trial wrapping up" Customer Journey (#291, journey #5).
    # Personalizes with board/communicator counts + the trial end date.
    # Inert until the journey ENV vars are configured.
    MailchimpTrialWrapJob.perform_async(user.id, trial_end)

    Rails.logger.info "[StripeWebhook] trial_will_end: user=#{user.id} sub=#{subscription.id}"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_trial_will_end error: #{e.class} - #{e.message}"
  end

  def handle_customer_created(customer)
    stripe_customer_id = customer.id
    user = User.find_by(stripe_customer_id: stripe_customer_id)
    # Also match by email before inviting: when email_signup creates the
    # Stripe customer, this webhook can race the stripe_customer_id save, and
    # invite! on the existing pending-invite user would rotate the
    # invitation_token — invalidating the magic link just emailed.
    user ||= User.find_by(email: customer.email&.downcase) if customer.email.present?
    if !user && customer.email.present?
      Rails.logger.error "[StripeWebhook] customer.created: no user found for customer #{stripe_customer_id} - Creating one"
      user = User.invite!(email: customer.email, skip_invitation: true)
    elsif !user
      Rails.logger.error "[StripeWebhook] customer.created: no user found for customer #{stripe_customer_id} and no email present"
      return
    end
    return unless user
    Rails.logger.info "[StripeWebhook] customer.created: customer #{customer.id} created"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_customer_created error: #{e.class} - #{e.message}"
  end

  # checkout.session.completed where metadata.kind == "topup".
  # Idempotent on the Stripe event id (unique index on credit_transactions).
  # Returns truthy when credits were granted (or already had been on a retry).
  def handle_topup_completed(session, event_id)
    metadata = session.metadata || {}

    user = User.find_by(id: metadata["user_id"]) if metadata["user_id"].present?
    user ||= User.find_by(stripe_customer_id: session.customer) if session.customer.present?
    user ||= User.find_by(email: session.customer_details&.email) if session.customer_details&.email.present?

    unless user
      Rails.logger.error "[StripeWebhook][topup] no user for session #{session.id}"
      return false
    end

    credit_amount = metadata["credit_amount"].to_i
    if credit_amount <= 0
      credit_amount = derive_credit_amount_from_session(session)
    end

    if credit_amount <= 0
      Rails.logger.error "[StripeWebhook][topup] no credit_amount derivable for session #{session.id}"
      return false
    end

    price_id = session.try(:line_items)&.data&.first&.price&.id

    CreditService.grant_topup!(
      user,
      amount: credit_amount,
      stripe_event_id: event_id,
      stripe_price_id: price_id,
      metadata: {
        checkout_session_id: session.id,
        pack_key: metadata["pack_key"],
        amount_total: session.amount_total,
        currency: session.currency,
      },
    )
    Rails.logger.info "[StripeWebhook][topup] credited user=#{user.id} amount=#{credit_amount} session=#{session.id}"

    # Checkout-completion analytics for topups (itty-bitty-frontend#307). The
    # credit grant above is idempotent on the event id, but a webhook retry may
    # re-capture this event; acceptable for analytics. `plan` is the user's
    # current plan — a topup doesn't pick one.
    PosthogService.capture_for_user(
      user,
      "checkout_completed",
      properties: {
        plan: user.plan_type,
        kind: "topup",
        amount_total: session.amount_total,
        currency: session.currency,
        source: "stripe_webhook",
      },
    )

    true
  rescue => e
    Rails.logger.error "[StripeWebhook][topup] error: #{e.class} - #{e.message}"
    false
  end

  # Last-resort lookup: read the line item Price's metadata.credit_amount.
  # Stripe's checkout.session.completed event does not include line_items by
  # default; we retrieve them with an expand.
  def derive_credit_amount_from_session(session)
    expanded = Stripe::Checkout::Session.retrieve(id: session.id, expand: ["line_items.data.price"])
    line_item = expanded.line_items&.data&.first
    return 0 unless line_item

    per_unit = line_item.price&.metadata&.[]("credit_amount").to_i
    quantity = line_item.quantity.to_i
    per_unit * (quantity.positive? ? quantity : 1)
  rescue => e
    Rails.logger.error "[StripeWebhook][topup] derive_credit_amount error: #{e.class} - #{e.message}"
    0
  end

  # Expect: you pass metadata[user_id] when creating the Checkout Session.
  def handle_checkout_completed(session)
    metadata = session.metadata || {}

    user = if metadata["user_id"].present?
        User.find_by(id: metadata["user_id"])
      else
        nil
      end

    if user.nil? && session.customer_details&.email.present?
      user = User.find_by(email: session.customer_details.email)
    end

    unless user
      Rails.logger.error "[StripeWebhook] checkout.session.completed: no user found for session #{session.id}"
      return
    end

    user.update!(
      stripe_customer_id: session.customer,
      stripe_subscription_id: session.subscription,
    )

    Rails.logger.info "[StripeWebhook] Linked checkout.session #{session.id} to user #{user.id}"

    # Authoritative checkout-completion event (itty-bitty-frontend#307) — fires
    # even when the user never returns to the success page. The frontend adds a
    # client-side echo separately. No event-id guard here (matching this
    # handler), so a Stripe webhook retry may re-capture; acceptable for
    # analytics. `paid_plan_type` is the plan picked at session create — the
    # subscription upsert may not have updated `plan_type` yet.
    PosthogService.capture_for_user(
      user,
      "checkout_completed",
      properties: {
        plan: user.paid_plan_type.presence || user.plan_type,
        kind: metadata["kind"].presence || "subscription",
        amount_total: session.amount_total,
        currency: session.currency,
        source: "stripe_webhook",
      },
    )

    user
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_checkout_completed error: #{e.class} - #{e.message}"
    nil
  end

  def handle_subscription_upsert(subscription)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook] subscription upsert: no user for customer #{subscription.customer}"
      # Return without retrying — Stripe will re-deliver the webhook if we 4xx,
      # and a blocking sleep in-request can wedge the worker under load.
      return
    end

    Rails.logger.info "[StripeWebhook] user #{user.email} found with role #{user.role} and plan_type #{user.plan_type}"
    if user.admin?
      Rails.logger.info "[StripeWebhook] subscription upsert: user #{user.id} is admin, skipping plan update"
      return
    end

    # A no-card reverse trial that ends without an upgrade lands here as
    # `unpaid` / `incomplete_expired` (terminal, no payment ever taken). Drop
    # the user to Free in fallback mode (#255) instead of leaving them stranded
    # in a non-active paid state. `past_due` is intentionally excluded — that's
    # a real payer's failed renewal where Stripe dunning should keep retrying
    # (handled by invoice.payment_failed). See issue #264.
    if TRIAL_LAPSED_STATUSES.include?(subscription.status)
      apply_free_plan(user, subscription.status)
      Rails.logger.info "[StripeWebhook] subscription upsert: user=#{user.id} status=#{subscription.status} -> downgraded to free (trial lapsed / unpaid)"
      return
    end

    previous_status = user.plan_status

    price = first_price_from_subscription(subscription)
    unless price
      Rails.logger.error "[StripeWebhook] subscription upsert: no price for subscription #{subscription.id}"
      return
    end

    meta = price.metadata || {}

    # Preserve the user's current plan_type when the Stripe Price has no
    # plan_type metadata. The old behavior silently downgraded paid users to
    # "free" any time a Price was misconfigured.
    plan_type = meta["plan_type"].presence
    if plan_type.blank?
      Rails.logger.warn "[StripeWebhook] subscription upsert: Price #{price.id} has no plan_type metadata; keeping user.plan_type=#{user.plan_type}"
      plan_type = user.plan_type.presence
    end

    user.plan_type = plan_type if plan_type.present?
    user.plan_status = subscription.status
    user.stripe_subscription_id ||= subscription.id

    # Persist the billing cadence so RefreshFreeTierCreditsJob can re-grant
    # yearly subscribers monthly (monthly subs refresh via invoice instead).
    interval = billing_interval_from_price(price)
    user.settings["billing_interval"] = interval if interval.present?

    user.setup_limits

    user.save!

    # Send the plan-correct welcome once we know what plan they're on. This is
    # the only path that delivers welcome_basic_email / welcome_pro_email to
    # web subscribers (mobile IAP welcomes happen in BillingController). Fires
    # on the first transition into `trialing` or `active`; idempotent per
    # plan_type via send_plan_welcome_email_once!, so subscription.updated
    # re-fires don't re-email and a real plan change still re-welcomes.
    if %w[trialing active].include?(subscription.status) && previous_status != subscription.status
      user.send_plan_welcome_email_once!(user.plan_type)
    end

    # Fire `subscription_started` on the trial→paid (or any non-active→active)
    # conversion so trial→paid is measurable against `trial_started`. Guarded on
    # the status transition so renewals (active→active) don't double-count.
    if subscription.status == "active" && previous_status != "active"
      AnalyticsEvent.track(
        "subscription_started",
        user_id: user.id,
        metadata: {
          plan_type: user.plan_type,
          previous_status: previous_status,
          subscription_id: subscription.id,
        },
      )
      # Server-side PostHog mirror (itty-bitty-frontend#307) so the money-path
      # funnel completes for users who never return to the success screen.
      PosthogService.capture_for_user(
        user,
        "subscription_started",
        properties: {
          plan: user.plan_type,
          billing_interval: billing_interval_from_price(price),
        },
      )
    end

    # Optional: team seats logic if this is a team plan
    if meta["team_seats"].present?
      # DISABLED FOR NOW -- TODO: finish testing
      # apply_team_limits_for(user, subscription, meta)
    end

    Rails.logger.info "[StripeWebhook] subscription upsert: user=#{user.id} plan_type=#{user.plan_type} status=#{user.plan_status}"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_subscription_upsert error: #{e.class} - #{e.message}"
  end

  # invoice.payment_succeeded fires for the initial paid period AND every
  # renewal — the canonical "the user just paid for another month" event.
  # Grants plan credits whose period_end = subscription.current_period_end.
  # Idempotent on the Stripe event id (one grant per invoice event).
  def handle_invoice_payment_succeeded(invoice, event_id)
    sub_id = subscription_id_from_invoice(invoice)
    return unless sub_id.present?

    # Look up the subscription to read its current_period_end and Price.metadata
    subscription = Stripe::Subscription.retrieve(sub_id)

    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook][invoice] no user for subscription #{sub_id}"
      return
    end
    return if user.admin?

    price = first_price_from_subscription(subscription)
    unless price
      Rails.logger.error "[StripeWebhook][invoice] no price for subscription #{sub_id}"
      return
    end

    meta = price.metadata || {}
    plan_type = meta["plan_type"].presence || user.plan_type.presence || "free"
    amount = (meta["monthly_credits"].presence || CreditService.monthly_credits_for(plan_type)).to_i
    return if amount <= 0

    period_end = period_end_from_subscription(subscription) || 30.days.from_now

    CreditService.grant_plan!(
      user,
      amount: amount,
      period_end: period_end,
      stripe_event_id: event_id,
      stripe_price_id: price.id,
      metadata: {
        invoice_id: invoice.id,
        subscription_id: sub_id,
        plan_type: plan_type,
        source: "invoice.payment_succeeded",
      },
    )
    Rails.logger.info "[StripeWebhook][invoice] granted user=#{user.id} amount=#{amount} period_end=#{period_end} sub=#{sub_id}"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_invoice_payment_succeeded error: #{e.class} - #{e.message}"
  end

  # Grant credits for the trial period when a subscription is created in
  # `trialing` status. No invoice has been paid yet, so the regular
  # invoice.payment_succeeded path won't fire until trial converts.
  # Idempotent on stripe_event_id.
  def handle_trial_credit_grant(subscription, event_id)
    return unless subscription.status == "trialing"

    user = find_user_for_subscription(subscription)
    return unless user
    return if user.admin?

    price = first_price_from_subscription(subscription)
    return unless price

    meta = price.metadata || {}
    plan_type = meta["plan_type"].presence || user.plan_type.presence || "free"
    amount = (meta["monthly_credits"].presence || CreditService.monthly_credits_for(plan_type)).to_i
    return if amount <= 0

    trial_end = subscription.respond_to?(:trial_end) ? subscription.trial_end : nil
    period_end = trial_end.present? ? Time.at(trial_end) : 14.days.from_now

    CreditService.grant_plan!(
      user,
      amount: amount,
      period_end: period_end,
      stripe_event_id: event_id,
      stripe_price_id: price.id,
      metadata: {
        subscription_id: subscription.id,
        plan_type: plan_type,
        source: "trial.subscription.created",
      },
    )
    Rails.logger.info "[StripeWebhook][trial] granted user=#{user.id} amount=#{amount} trial_end=#{period_end}"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_trial_credit_grant error: #{e.class} - #{e.message}"
  end

  # A trial only truly begins when Stripe creates the subscription with a trial
  # period (status "trialing") — so we fire the server-side PostHog
  # `trial_started` here rather than from the frontend (itty-bitty-frontend#307).
  # PostHog-only: the internal `trial_started` AnalyticsEvent is already recorded
  # at checkout (CheckoutSessionsController), so we don't double-count there.
  # Called only from `customer.subscription.created`, so it can't re-fire on
  # trialing→trialing updates.
  def handle_trial_started_analytics(subscription)
    return unless subscription.status == "trialing"

    user = find_user_for_subscription(subscription)
    return unless user
    return if user.admin?

    price = first_price_from_subscription(subscription)
    plan = (price&.metadata || {})["plan_type"].presence || user.plan_type

    PosthogService.capture_for_user(
      user,
      "trial_started",
      properties: { plan: plan },
      set: { plan: plan },
    )
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_trial_started_analytics error: #{e.class} - #{e.message}"
  end

  # Mark the user's subscription as past_due. Stripe will keep retrying
  # the charge per its dunning rules; we just need state visibility so
  # downstream code (and the user) can see something went wrong. We do NOT
  # downgrade the plan here — Stripe will fire `customer.subscription.deleted`
  # if the dunning attempts fail out.
  def handle_invoice_payment_failed(invoice)
    sub_id = subscription_id_from_invoice(invoice)
    return unless sub_id.present?

    subscription = Stripe::Subscription.retrieve(sub_id)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook][invoice_failed] no user for subscription #{sub_id}"
      return
    end
    return if user.admin?

    user.update!(plan_status: "past_due")
    Rails.logger.info "[StripeWebhook][invoice_failed] marked user=#{user.id} plan_status=past_due sub=#{sub_id}"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_invoice_payment_failed error: #{e.class} - #{e.message}"
  end

  # Read the subscription id off an invoice. The newer Stripe API
  # (2024-06-20+) exposes it at `invoice.parent.subscription_details.subscription`
  # while older API versions use `invoice.subscription` directly. Read both,
  # prefer the new path.
  def subscription_id_from_invoice(invoice)
    if invoice.respond_to?(:parent) && invoice.parent
      parent = invoice.parent
      if parent.respond_to?(:subscription_details) && parent.subscription_details
        details = parent.subscription_details
        new_id = details.respond_to?(:subscription) ? details.subscription : nil
        return new_id if new_id.present?
      end
    end
    invoice.respond_to?(:subscription) ? invoice.subscription : nil
  end

  # Pull current_period_end off a Subscription regardless of whether the
  # Stripe SDK gives us a Time or an integer Unix timestamp.
  def period_end_from_subscription(subscription)
    raw = subscription.respond_to?(:current_period_end) ? subscription.current_period_end : nil
    return nil if raw.blank?
    raw.is_a?(Integer) ? Time.at(raw) : raw
  end

  def handle_subscription_deleted(subscription)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook] subscription deleted: no user for customer #{subscription.customer}"
      return
    end

    # Capture the plan we're leaving BEFORE apply_free_plan resets it to "free".
    cancelled_plan = user.plan_type
    reason = cancellation_reason_from_subscription(subscription)

    apply_free_plan(user)
    Rails.logger.info "[StripeWebhook] subscription deleted: downgraded user=#{user.id} to free"

    # Internal + PostHog analytics for the cancellation (itty-bitty-frontend#307).
    # Cancellation happens entirely inside Stripe's billing portal, so the
    # frontend never sees it — capture it server-side. $set plan -> "free"
    # (user.plan_type is now free after apply_free_plan) keeps cohorts correct.
    AnalyticsEvent.track(
      "subscription_canceled",
      user_id: user.id,
      metadata: {
        plan_type: cancelled_plan,
        reason: reason,
        subscription_id: subscription.id,
      },
    )
    PosthogService.capture_for_user(
      user,
      "subscription_cancelled",
      properties: { plan: cancelled_plan, reason: reason },
    )
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_subscription_deleted error: #{e.class} - #{e.message}"
  end

  def handle_subscription_paused(subscription)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook] subscription paused: no user for customer #{subscription.customer}"
      return
    end
    apply_free_plan(user, "paused")
    Rails.logger.info "[StripeWebhook] subscription paused: user=#{user.id} status=paused"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_subscription_paused error: #{e.class} - #{e.message}"
  end

  # ========== Helper methods ==========

  def find_user_for_subscription(subscription)
    customer_id = subscription.customer
    return if customer_id.blank?

    user = User.find_by(stripe_customer_id: customer_id)
    return user if user

    # Fallback: try email from Stripe Customer
    begin
      customer = Stripe::Customer.retrieve(customer_id)
      if customer.respond_to?(:email) && customer.email.present?
        user = User.find_by(email: customer.email)
        if user && user.stripe_customer_id.blank?
          user.update!(stripe_customer_id: customer_id)
        end
      end
      user
    rescue => e
      Rails.logger.error "[StripeWebhook] find_user_for_subscription: error retrieving customer #{customer_id} - #{e.message}"
      nil
    end
  end

  def first_price_from_subscription(subscription)
    item = subscription.items&.data&.first
    return nil unless item
    item.price
  end

  # Map a Stripe Price's recurring interval to the frontend's billing_interval
  # values ("monthly" / "yearly") so the money-path funnel lines up across
  # client- and server-fired events. Returns nil when no recurring interval is
  # present (defensive — one-time prices, or a Price without `recurring`).
  def billing_interval_from_price(price)
    recurring = price.respond_to?(:recurring) ? price.recurring : nil
    return nil if recurring.nil?

    interval = recurring.respond_to?(:interval) ? recurring.interval : recurring["interval"]
    case interval
    when "month" then "monthly"
    when "year" then "yearly"
    else interval
    end
  rescue => e
    Rails.logger.error "[StripeWebhook] billing_interval_from_price error: #{e.class} - #{e.message}"
    nil
  end

  # Best-effort cancellation reason from Stripe's cancellation_details
  # (feedback is the user-selected reason in the billing portal; reason is the
  # system reason). nil when Stripe didn't collect one.
  def cancellation_reason_from_subscription(subscription)
    details = subscription.respond_to?(:cancellation_details) ? subscription.cancellation_details : nil
    return nil if details.nil?

    feedback = details.respond_to?(:feedback) ? details.feedback : details["feedback"]
    reason = details.respond_to?(:reason) ? details.reason : details["reason"]
    feedback.presence || reason.presence
  rescue => e
    Rails.logger.error "[StripeWebhook] cancellation_reason_from_subscription error: #{e.class} - #{e.message}"
    nil
  end

  def apply_team_limits_for(user, subscription, meta)
    base_seats = to_int_or_nil(meta["team_seats"])
    return unless base_seats

    quantity = subscription.items&.data&.first&.quantity || 1
    total_seats = base_seats * quantity

    # Adjust this to match your actual associations:
    team = user.try(:team) || user.try(:teams)&.first
    unless team
      Rails.logger.info "[StripeWebhook] apply_team_limits_for: no team for user #{user.id}"
      return
    end

    if team.respond_to?(:seat_limit=)
      team.update!(seat_limit: total_seats)
      Rails.logger.info "[StripeWebhook] apply_team_limits_for: team=#{team.id} seat_limit=#{total_seats}"
    end
  end

  # Downgrade-to-free now lives in Billing::PlanTransitions so the Stripe and
  # RevenueCat webhooks share one code path.
  def apply_free_plan(user, status = "canceled")
    Billing::PlanTransitions.apply_free_plan(user, status)
  end

  def to_int_or_nil(value)
    return nil if value.blank?
    value.to_i
  end
end
