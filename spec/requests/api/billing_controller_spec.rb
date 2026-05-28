require "rails_helper"

# Covers the RevenueCat / App Store hand-off endpoint. Native clients call
# this directly after the OS-level purchase completes; there's no Stripe
# webhook in this path, so the server has to trust the client and flip
# plan_type / plan_status itself.
RSpec.describe "POST /api/billing/update_subscription", type: :request do
  let(:user) { FactoryBot.create(:user, plan_type: "free", created_at: 1.year.ago) }

  before do
    # Don't actually fire emails in request specs.
    allow_any_instance_of(User).to receive(:send_welcome_email)
  end

  it "upgrades a free user to basic and records purchase_platform" do
    expect {
      post "/api/billing/update_subscription",
           params: { plan_key: "basic", purchase_platform: "ios" },
           headers: auth_headers(user)
    }.to change { user.reload.plan_type }.from("free").to("basic")

    expect(response).to have_http_status(:ok)
    expect(user.plan_status).to eq("active")
    expect(user.settings["purchase_platform"]).to eq("ios")
    expect(JSON.parse(response.body)).to eq("success" => true, "plan_key" => "basic")
  end

  it "upgrades a free user to pro" do
    post "/api/billing/update_subscription",
         params: { plan_key: "pro", purchase_platform: "android" },
         headers: auth_headers(user)

    expect(user.reload.plan_type).to eq("pro")
    expect(user.settings["purchase_platform"]).to eq("android")
  end

  it "applies the plan's limits (Basic plan board_limit)" do
    post "/api/billing/update_subscription",
         params: { plan_key: "basic", purchase_platform: "ios" },
         headers: auth_headers(user)

    expect(user.reload.settings["board_limit"]).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
  end

  it "rejects an unknown plan_key with 400" do
    post "/api/billing/update_subscription",
         params: { plan_key: "premium" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)["error"]).to eq("Invalid plan_key")
    expect(user.reload.plan_type).to eq("free")
  end

  it "rejects an empty plan_key with 400" do
    post "/api/billing/update_subscription",
         params: { plan_key: "" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)["error"]).to eq("plan_key is required")
  end

  it "sends the welcome email after upgrade" do
    expect_any_instance_of(User).to receive(:send_welcome_email).with("basic")

    post "/api/billing/update_subscription",
         params: { plan_key: "basic", purchase_platform: "ios" },
         headers: auth_headers(user)
  end

  it "is auth-gated (no token → unauthorized)" do
    post "/api/billing/update_subscription",
         params: { plan_key: "basic" }

    expect(response).to have_http_status(:unauthorized)
  end
end
