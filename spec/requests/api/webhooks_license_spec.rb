require "rails_helper"

RSpec.describe "POST /api/webhooks (5-Year license)", type: :request do
  include StripeHelpers

  let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_lic_hook") }

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def build_license_session(overrides = {})
    metadata = {
      "kind" => "license",
      "user_id" => user.id.to_s,
      "plan_type" => "pro_5yr",
      "license_years" => "5",
      "monthly_credits" => "1500",
    }.merge(overrides.delete(:metadata) || {})

    OpenStruct.new(
      {
        id: "cs_test_lic_#{SecureRandom.hex(4)}",
        status: "complete",
        customer: "cus_lic_hook",
        customer_details: OpenStruct.new(email: user.email),
        amount_total: 49900,
        currency: "usd",
        metadata: metadata,
      }.merge(overrides),
    )
  end

  def stub_event(session_object, event_id: "evt_lic_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(
      id: event_id,
      type: "checkout.session.completed",
      data: OpenStruct.new(object: session_object),
    )
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  it "grants the license: sets plan_type, ~5yr expiry, credits once (idempotent on event id)" do
    session = build_license_session
    event = stub_event(session)

    expect {
      post_webhook("{}", header_with_signature)
    }.to change { user.reload.plan_type }.to("pro_5yr")

    expect(response).to have_http_status(:ok)
    expect(user.plan_status).to eq("active")
    expect(user.plan_expires_at).to be_within(2.days).of(5.years.from_now)
    expect(user.plan_credits_balance).to eq(1500)
    expect(CreditTransaction.where(stripe_event_id: event.id, kind: "plan_grant").count).to eq(1)

    # Replay the same event — no double grant.
    expect {
      post_webhook("{}", header_with_signature)
    }.not_to change { user.reload.plan_credits_balance }
    expect(CreditTransaction.where(stripe_event_id: event.id, kind: "plan_grant").count).to eq(1)
  end

  it "does not grant when the session is not complete" do
    session = build_license_session(status: "open")
    stub_event(session)

    # Baseline is the free signup grant (25); the webhook must add nothing.
    expect {
      post_webhook("{}", header_with_signature)
    }.not_to change { user.reload.plan_credits_balance }
    expect(user.plan_type).not_to eq("pro_5yr")
  end

  it "does not grant for an unknown plan_type" do
    session = build_license_session(metadata: { "plan_type" => "gold_5yr" })
    stub_event(session)

    expect {
      post_webhook("{}", header_with_signature)
    }.not_to change { user.reload.plan_type }
  end

  it "does not grant when no matching user can be resolved" do
    session = build_license_session(
      customer: nil,
      customer_details: nil,
      metadata: { "user_id" => "0" },
    )
    stub_event(session)

    post_webhook("{}", header_with_signature)
    expect(user.reload.plan_type).not_to eq("pro_5yr")
    expect(JSON.parse(response.body)["error"]).to eq("license_not_granted")
  end
end
