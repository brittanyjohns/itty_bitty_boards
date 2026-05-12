require "rails_helper"

RSpec.describe "POST /api/webhooks (top-up)", type: :request do
  include StripeHelpers

  let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_topup_user") }

  # The webhook handler does `ENV.fetch("STRIPE_WEBHOOK_SECRET")`; we stub
  # Stripe::Webhook.construct_event below so the actual secret doesn't matter,
  # but ENV.fetch still needs a non-nil value to avoid raising before the stub.
  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def build_topup_session(overrides = {})
    OpenStruct.new(
      {
        id: "cs_test_topup_#{SecureRandom.hex(4)}",
        customer: "cus_topup_user",
        customer_details: OpenStruct.new(email: user.email),
        amount_total: 499,
        currency: "usd",
        metadata: {
          "kind" => "topup",
          "user_id" => user.id.to_s,
          "pack_key" => "small",
          "credit_amount" => "100",
        },
      }.merge(overrides),
    )
  end

  def stub_event(session_object, type: "checkout.session.completed", event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(
      id: event_id,
      type: type,
      data: OpenStruct.new(object: session_object),
    )
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  it "grants top-up credits and is idempotent on the Stripe event id" do
    session = build_topup_session
    event = stub_event(session)

    expect {
      post_webhook("{}", header_with_signature)
    }.to change { user.reload.topup_credits_balance }.from(0).to(100)
    expect(response).to have_http_status(:ok)
    expect(CreditTransaction.where(stripe_event_id: event.id).count).to eq(1)

    # Replay the same event
    expect {
      post_webhook("{}", header_with_signature)
    }.not_to change { user.reload.topup_credits_balance }
    expect(CreditTransaction.where(stripe_event_id: event.id).count).to eq(1)
  end

  it "uses metadata.credit_amount even when the price metadata is absent" do
    session = build_topup_session(metadata: {
      "kind" => "topup",
      "user_id" => user.id.to_s,
      "credit_amount" => "750",
    })
    stub_event(session)

    expect(Stripe::Checkout::Session).not_to receive(:retrieve)

    post_webhook("{}", header_with_signature)
    expect(user.reload.topup_credits_balance).to eq(750)
  end

  it "falls back to retrieving line_items when credit_amount is missing from metadata" do
    session = build_topup_session(metadata: { "kind" => "topup", "user_id" => user.id.to_s })
    stub_event(session)

    fake_price_metadata = Class.new do
      def [](k) = { "credit_amount" => "500" }[k]
    end.new
    expanded = OpenStruct.new(
      line_items: OpenStruct.new(
        data: [
          OpenStruct.new(
            quantity: 2,
            price: OpenStruct.new(metadata: fake_price_metadata, id: "price_topup_medium"),
          ),
        ],
      ),
    )
    expect(Stripe::Checkout::Session).to receive(:retrieve).and_return(expanded)

    post_webhook("{}", header_with_signature)
    expect(user.reload.topup_credits_balance).to eq(1000) # 500 * 2
  end

  it "logs an error and reports topup_not_credited when no user can be found" do
    session = OpenStruct.new(
      id: "cs_topup_nouser",
      customer: "cus_unknown",
      customer_details: OpenStruct.new(email: "nobody@example.com"),
      metadata: { "kind" => "topup", "credit_amount" => "100" },
    )
    stub_event(session)

    post_webhook("{}", header_with_signature)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["error"]).to eq("topup_not_credited")
  end

  it "does not affect the existing subscription checkout flow" do
    session = OpenStruct.new(
      id: "cs_sub_normal",
      customer: "cus_topup_user",
      subscription: "sub_abc",
      customer_details: OpenStruct.new(email: user.email),
      metadata: { "user_id" => user.id.to_s }, # no `kind` key
    )
    stub_event(session)

    expect {
      post_webhook("{}", header_with_signature)
    }.not_to change { user.reload.topup_credits_balance }
    expect(user.reload.stripe_subscription_id).to eq("sub_abc")
  end
end
