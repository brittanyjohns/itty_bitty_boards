require "rails_helper"

# Covers the whole-handler idempotency gate on the Stripe webhook
# (API::WebhooksController#webhooks). Stripe resends the same event id on
# delivery retries and dashboard replays; the gate records an event only after a
# clean run and short-circuits any later delivery of that id, so non-credit
# handlers (apply_free_plan on delete/pause) don't re-run and pollute the ledger.
RSpec.describe "POST /api/webhooks (Stripe idempotency gate)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_idem",
      stripe_subscription_id: "sub_idem",
      plan_type: "pro",
      plan_status: "active")
  end

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def stub_event(object, type:, event_id:)
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def deleted_sub
    OpenStruct.new(id: "sub_idem", customer: user.stripe_customer_id, status: "canceled")
  end

  it "processes a new event once and records it for audit" do
    stub_event(deleted_sub, type: "customer.subscription.deleted", event_id: "evt_idem_new")

    post_webhook("{}", header_with_signature)

    expect(response).to have_http_status(:ok)
    expect(user.reload.plan_type).to eq("free")
    row = ProcessedWebhookEvent.where(provider: "stripe", event_id: "evt_idem_new")
    expect(row.count).to eq(1)
    expect(row.first.event_type).to eq("customer.subscription.deleted")
  end

  it "skips a replayed event id without re-running the downgrade handler" do
    stub_event(deleted_sub, type: "customer.subscription.deleted", event_id: "evt_idem_dup")

    post_webhook("{}", header_with_signature)
    expect(user.reload.plan_type).to eq("free")

    # Replay the identical event — apply_free_plan must NOT run again, so no new
    # expire/grant rows land on the ledger.
    expect {
      post_webhook("{}", header_with_signature)
    }.not_to change { user.reload.credit_transactions.count }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["status"]).to eq("already_processed")
    expect(ProcessedWebhookEvent.where(provider: "stripe", event_id: "evt_idem_dup").count).to eq(1)
  end

  it "processes two distinct event ids independently" do
    stub_event(deleted_sub, type: "customer.subscription.deleted", event_id: "evt_idem_a")
    post_webhook("{}", header_with_signature)

    stub_event(deleted_sub, type: "customer.subscription.deleted", event_id: "evt_idem_b")
    post_webhook("{}", header_with_signature)

    expect(ProcessedWebhookEvent.where(provider: "stripe").pluck(:event_id))
      .to contain_exactly("evt_idem_a", "evt_idem_b")
  end
end
