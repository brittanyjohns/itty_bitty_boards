require "rails_helper"

RSpec.describe "GET /api/me/credits", type: :request do
  let(:user) { FactoryBot.create(:user, plan_type: "basic") }

  # Start from a clean ledger so each example dictates its own balances
  # rather than fighting the after_create free-tier grant.
  before { reset_user_credits!(user) }

  def auth
    auth_headers(user)
  end

  it "requires authentication" do
    get "/api/me/credits"
    expect(response).not_to have_http_status(:ok)
  end

  it "returns both buckets, the total, and the granted monthly allowance" do
    CreditService.grant_plan!(user, amount: 400, period_end: 30.days.from_now)
    CreditService.grant_topup!(user, amount: 978)
    CreditService.spend!(user.reload, amount: 400, feature_key: "image_generation")

    get "/api/me/credits", headers: auth
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body).to include(
      "plan" => 0,
      "topup" => 978,
      "total" => 978,
      "plan_type" => "basic",
      "plan_allowance" => 400,
    )
    expect(body["reset_at"]).to be_present
  end

  it "serves the granted allowance even when it differs from the plan default" do
    CreditService.grant_plan!(user, amount: 900, period_end: 30.days.from_now)

    get "/api/me/credits", headers: auth
    body = JSON.parse(response.body)

    expect(body["plan_allowance"]).to eq(900)
  end

  it "falls back to the plan default for a user with no grant on record" do
    get "/api/me/credits", headers: auth
    body = JSON.parse(response.body)

    expect(body["plan_allowance"]).to eq(CreditService.monthly_credits_for("basic"))
    expect(body["total"]).to eq(0)
  end
end
