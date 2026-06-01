require "rails_helper"

RSpec.describe "GET /api/credits/feature_costs", type: :request do
  it "returns 200 without authentication" do
    get "/api/credits/feature_costs"
    expect(response).to have_http_status(:ok)
  end

  it "returns feature_costs mirroring CreditService::FEATURE_COSTS (minus the legacy ai_action key)" do
    get "/api/credits/feature_costs"
    body = JSON.parse(response.body)

    expect(body).to have_key("feature_costs")
    expected = CreditService::FEATURE_COSTS.except("ai_action")
    expect(body["feature_costs"]).to eq(expected)
  end

  it "does not expose the legacy ai_action shadow-mode key" do
    get "/api/credits/feature_costs"
    body = JSON.parse(response.body)
    expect(body["feature_costs"]).not_to have_key("ai_action")
  end
end
