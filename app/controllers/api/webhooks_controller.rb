# frozen_string_literal: true

class API::WebhooksController < API::ApplicationController
  skip_before_action :authenticate_token!, only: :webhooks
  protect_from_forgery except: :webhooks if respond_to?(:protect_from_forgery)

  FREE_PLAN_LIMITS = {
    "plan_type" => "free",
    "board_limit" => 1,
    "paid_communicator_limit" => 0,
    "demo_communicator_limit" => 0,
    "ai_daily_limit" => 5,
  }.freeze

  def webhooks
    payload = request.body.read
    sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

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

    case event.type
    when "customer.created"
      handle_customer_created(event.data.object)
    when "checkout.session.completed"
      handle_checkout_completed(event.data.object)
    when "customer.subscription.created", "customer.subscription.updated"
      handle_subscription_upsert(event.data.object, event.type == "customer.subscription.created")
    when "customer.subscription.deleted"
      handle_subscription_deleted(event.data.object)
    when "customer.subscription.paused"
      handle_subscription_paused(event.data.object)
    else
      Rails.logger.info "[StripeWebhook] Ignoring unhandled event type=#{event.type}"
    end

    render json: { success: true }
  rescue => e
    Rails.logger.error "[StripeWebhook] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
    render json: { error: "server_error" }, status: :bad_request
  end

  private

  # ========== Event handlers ==========

  def handle_customer_created(customer)
    stripe_customer_id = customer.id
    user = User.find_by(stripe_customer_id: stripe_customer_id)
    return unless user
    user.send_general_welcome_email
    # You can implement logic here if needed when a Stripe Customer is created.
    Rails.logger.info "[StripeWebhook] customer.created: customer #{customer.id} created"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_customer_created error: #{e.class} - #{e.message}"
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
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_checkout_completed error: #{e.class} - #{e.message}"
  end

  def handle_subscription_upsert(subscription, is_create_event = false)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook] subscription upsert: no user for customer #{subscription.customer}"
      return
    end

    price = first_price_from_subscription(subscription)
    unless price
      Rails.logger.error "[StripeWebhook] subscription upsert: no price for subscription #{subscription.id}"
      return
    end

    meta = price.metadata || {}

    plan_type = meta["plan_type"].presence || "free"

    user.plan_type = plan_type
    user.plan_status = subscription.status
    user.stripe_subscription_id ||= subscription.id

    paid_communicator_limit = meta["paid_communicator_limit"] || meta["communicator_limit"]
    user.settings ||= {}
    user.settings["board_limit"] = to_int_or_nil(meta["board_limit"])
    user.settings["paid_communicator_limit"] = to_int_or_nil(paid_communicator_limit)
    user.settings["demo_communicator_limit"] = to_int_or_nil(meta["demo_communicator_limit"])
    user.settings["ai_daily_limit"] = to_int_or_nil(meta["ai_daily_limit"])

    # Optional: role controlled via Stripe metadata
    user.role = meta["role"] if meta["role"].present?

    user.save!

    if is_create_event
      # Send welcome email on new subscriptions
      begin
        user.send_welcome_email(plan_type, meta["username"])

        Rails.logger.info "[StripeWebhook] subscription upsert: sent welcome email to user #{user.id}"
      rescue => e
        Rails.logger.error "[StripeWebhook] subscription upsert: error sending welcome email to user #{user.id} - #{e.message}"
      end
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

  def handle_subscription_deleted(subscription)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook] subscription deleted: no user for customer #{subscription.customer}"
      return
    end

    apply_free_plan(user)
    Rails.logger.info "[StripeWebhook] subscription deleted: downgraded user=#{user.id} to free"
  rescue => e
    Rails.logger.error "[StripeWebhook] handle_subscription_deleted error: #{e.class} - #{e.message}"
  end

  def handle_subscription_paused(subscription)
    user = find_user_for_subscription(subscription)
    unless user
      Rails.logger.error "[StripeWebhook] subscription paused: no user for customer #{subscription.customer}"
      return
    end

    # You can decide how "paused" behaves in your app.
    user.update!(
      plan_status: "paused",
      # plan_type: "free" # uncomment if you want paused users treated as free
    )

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

  def apply_free_plan(user)
    user.plan_type = FREE_PLAN_LIMITS["plan_type"]
    user.plan_status = "canceled"

    user.settings ||= {}
    user.settings["board_limit"] = FREE_PLAN_LIMITS["board_limit"]
    user.settings["paid_communicator_limit"] = FREE_PLAN_LIMITS["paid_communicator_limit"]
    user.settings["demo_communicator_limit"] = FREE_PLAN_LIMITS["demo_communicator_limit"]
    user.settings["ai_daily_limit"] = FREE_PLAN_LIMITS["ai_daily_limit"]

    user.stripe_subscription_id = nil
    user.save!
  end

  def to_int_or_nil(value)
    return nil if value.blank?
    value.to_i
  end
end
