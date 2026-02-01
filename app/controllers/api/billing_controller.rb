class API::BillingController < API::ApplicationController
  before_action :authenticate_token!

  def update_subscription
    plan_key = params[:plan_key]
    purchase_platform = params[:purchase_platform] || ""
    if plan_key.blank?
      render json: { error: "plan_key is required" }, status: :bad_request
      return
    end
    begin
      acceptable_plans = %w[myspeak basic pro]
      unless acceptable_plans.include?(plan_key)
        render json: { error: "Invalid plan_key" }, status: :bad_request
        return
      end
      current_user.plan_type = plan_key
      current_user.plan_status = "active"
      current_user.settings["purchase_platform"] = purchase_platform
      current_user.save!
      render json: { success: true, plan_key: plan_key }
    rescue StandardError => e
      Rails.logger.error "Failed to update subscription for User ID: #{current_user.id}, Plan Key: #{plan_key} - Error: #{e.message}"
      render json: { error: "Failed to update subscription: #{e.message}" }, status: :unprocessable_entity
    end
  end
end
