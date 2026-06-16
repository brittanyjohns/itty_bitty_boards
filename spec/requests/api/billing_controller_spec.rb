require "rails_helper"

# Covers the RevenueCat / App Store hand-off endpoint. Native clients call this
# right after the OS-level purchase completes. The server does NOT trust the
# client's claimed plan: it verifies the entitlement against RevenueCat's REST
# API before flipping plan_type / plan_status.
RSpec.describe "POST /api/billing/update_subscription", type: :request do
  let(:user) { FactoryBot.create(:user, plan_type: "free", created_at: 1.year.ago) }

  before do
    # Don't actually fire emails in request specs.
    allow_any_instance_of(User).to receive(:send_welcome_email)
  end

  def stub_rc_verified(plan_type:, ok: true)
    allow_any_instance_of(RevenueCat::Client).to receive(:verified_plan_for)
      .and_return(RevenueCat::Client::Result.new(ok?: ok, plan_type: plan_type))
  end

  it "upgrades a verified free user to basic and records purchase_platform" do
    stub_rc_verified(plan_type: "basic")

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

  it "upgrades a verified free user to pro" do
    stub_rc_verified(plan_type: "pro")

    post "/api/billing/update_subscription",
         params: { plan_key: "pro", purchase_platform: "android" },
         headers: auth_headers(user)

    expect(user.reload.plan_type).to eq("pro")
    expect(user.settings["purchase_platform"]).to eq("android")
  end

  it "does NOT clobber an in-progress trial to active for the same plan" do
    # The RC webhook marked this trialist 'trialing'; the racing client call must
    # not flip it to 'active' (which would mask the trial).
    user.update!(plan_type: "pro", plan_status: "trialing")
    stub_rc_verified(plan_type: "pro")

    post "/api/billing/update_subscription",
         params: { plan_key: "pro", purchase_platform: "ios" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(user.reload.plan_status).to eq("trialing")
  end

  it "applies the plan's limits (Basic plan board_limit)" do
    stub_rc_verified(plan_type: "basic")

    post "/api/billing/update_subscription",
         params: { plan_key: "basic", purchase_platform: "ios" },
         headers: auth_headers(user)

    expect(user.reload.settings["board_limit"]).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
  end

  it "rejects with 403 when RevenueCat can't verify the entitlement" do
    stub_rc_verified(plan_type: nil, ok: false)

    post "/api/billing/update_subscription",
         params: { plan_key: "basic", purchase_platform: "ios" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("Subscription could not be verified")
    expect(user.reload.plan_type).to eq("free")
  end

  it "rejects with 403 when the verified plan doesn't match the claimed plan" do
    stub_rc_verified(plan_type: "basic") # verified basic, but client claims pro

    post "/api/billing/update_subscription",
         params: { plan_key: "pro", purchase_platform: "ios" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:forbidden)
    expect(user.reload.plan_type).to eq("free")
  end

  it "rejects an unknown plan_key with 400 (before hitting RevenueCat)" do
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

  it "sends the welcome email after a verified upgrade" do
    stub_rc_verified(plan_type: "basic")
    expect_any_instance_of(User).to receive(:send_welcome_email).with("basic")

    post "/api/billing/update_subscription",
         params: { plan_key: "basic", purchase_platform: "ios" },
         headers: auth_headers(user)
  end

  it "only sends the welcome email once across repeated verified calls (idempotent)" do
    stub_rc_verified(plan_type: "basic")
    # Override the global no-op stub so the real send_plan_welcome_email_once!
    # guard runs; spy on the mailer to count actual sends.
    allow_any_instance_of(User).to receive(:send_welcome_email).and_call_original
    allow(UserMailer).to receive(:welcome_basic_email).and_return(double(deliver_later: true))

    2.times do
      post "/api/billing/update_subscription",
           params: { plan_key: "basic", purchase_platform: "ios" },
           headers: auth_headers(user)
    end

    expect(response).to have_http_status(:ok)
    expect(UserMailer).to have_received(:welcome_basic_email).once
    expect(user.reload.settings["plan_welcome_sent_for"]).to include("basic")
  end

  it "is auth-gated (no token → unauthorized)" do
    post "/api/billing/update_subscription",
         params: { plan_key: "basic" }

    expect(response).to have_http_status(:unauthorized)
  end
end
