class API::BillingController < API::ApplicationController
  before_action :authenticate_token!, except: :webhooks
  skip_before_action :authenticate_token!, only: :webhooks
  protect_from_forgery except: :webhooks if respond_to?(:protect_from_forgery)

  # Native clients call this right after an App Store / Play purchase completes.
  # We do NOT trust the client's claimed plan: before flipping plan_type we ask
  # RevenueCat's REST API whether this user actually owns the entitlement. The
  # webhook is the sole credit-grant authority (mirrors the Stripe path), so we
  # only set plan_type/plan_status here.
  def update_subscription
    plan_key = params[:plan_key]
    purchase_platform = params[:purchase_platform] || ""
    if plan_key.blank?
      render json: { error: "plan_key is required" }, status: :bad_request
      return
    end

    unless %w[basic pro].include?(plan_key)
      render json: { error: "Invalid plan_key" }, status: :bad_request
      return
    end

    normalized_plan_key = normalize_plan_key(plan_key)

    result = RevenueCat::Client.new.verified_plan_for(current_user.id.to_s)
    unless result.ok? && result.plan_type == normalized_plan_key
      Rails.logger.warn "[Billing] update_subscription rejected user=#{current_user.id} " \
        "claimed=#{normalized_plan_key} verified=#{result.plan_type.inspect} ok=#{result.ok?}"
      render json: { error: "Subscription could not be verified" }, status: :forbidden
      return
    end

    begin
      # Don't clobber an in-progress trial. The RC webhook marks a trialist
      # "trialing" (period_type=TRIAL); this client call races it after the same
      # purchase and verified_plan_for can't see the trial flag, so preserve the
      # trialing status for the same plan and let the webhook own trial→active.
      keep_trialing = current_user.plan_status == "trialing" && current_user.plan_type == normalized_plan_key
      current_user.plan_type = normalized_plan_key
      current_user.plan_status = keep_trialing ? "trialing" : "active"
      current_user.settings["purchase_platform"] = purchase_platform
      # setup_limits runs as a before_save callback when plan_type changes.
      current_user.save!
      # Idempotent per plan_type: a retried client call (or a later upgrade that
      # re-hits this endpoint for the same plan) won't re-email. Matches the
      # Stripe webhook path, which also uses send_plan_welcome_email_once!.
      current_user.send_plan_welcome_email_once!(current_user.plan_type)
      render json: { success: true, plan_key: plan_key }
    rescue StandardError => e
      Rails.logger.error "Failed to update subscription for User ID: #{current_user.id}, Plan Key: #{plan_key} - Error: #{e.message}"
      render json: { error: "Failed to update subscription: #{e.message}" }, status: :unprocessable_entity
    end
  end

  # RevenueCat subscription lifecycle webhook. Verifies the shared-secret
  # Authorization header, then hands the event to RevenueCat::WebhookProcessor.
  def webhooks
    unless RevenueCat::WebhookProcessor.authorized?(request.headers["Authorization"])
      render json: { error: "unauthorized" }, status: :unauthorized
      return
    end

    payload = JSON.parse(request.body.read)
    result = RevenueCat::WebhookProcessor.new(payload).process
    render json: { status: result.status }, status: result.http_status
  rescue JSON::ParserError => e
    Rails.logger.error "[RCWebhook] JSON parse error: #{e.message}"
    render json: { error: "invalid_payload" }, status: :bad_request
  rescue => e
    Rails.logger.error "[RCWebhook] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: "server_error" }, status: :bad_request
  end
end
