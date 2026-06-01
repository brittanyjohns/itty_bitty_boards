class API::CreditsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[feature_costs]

  # GET /api/credits/feature_costs
  # Public endpoint that mirrors CreditService::FEATURE_COSTS so the frontend
  # /upgrade page can render server-truth costs without a duplicated TS constant.
  def feature_costs
    render json: { feature_costs: CreditService::FEATURE_COSTS.except("ai_action") }
  end
end
