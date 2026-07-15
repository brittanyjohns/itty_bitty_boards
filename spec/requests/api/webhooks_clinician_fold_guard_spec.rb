require "rails_helper"

# Part 3 (partner fold): when partners:fold_into_clinicians cancels a folded
# partner's old partner_pro no-card trial, Stripe fires
# customer.subscription.deleted. The already-clinician guard in
# handle_subscription_deleted must NOT dump the clinician back to Free.
RSpec.describe "POST /api/webhooks — clinician fold guard", type: :request do
  include StripeHelpers

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def stub_deleted_event(customer_id)
    subscription = OpenStruct.new(
      id: "sub_deleted_#{SecureRandom.hex(3)}",
      customer: customer_id,
      status: "canceled",
      cancellation_details: nil,
    )
    event = OpenStruct.new(
      id: "evt_del_#{SecureRandom.hex(4)}",
      type: "customer.subscription.deleted",
      data: OpenStruct.new(object: subscription),
    )
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  it "does not downgrade a clinician when their old partner trial cancels" do
    clinician = FactoryBot.create(:user, plan_type: "clinician", stripe_customer_id: "cus_folded")
    stub_deleted_event("cus_folded")

    expect(UserMailer).not_to receive(:subscription_canceled_email)

    post_webhook("{}", header_with_signature)

    expect(response).to have_http_status(:ok)
    expect(clinician.reload.plan_type).to eq("clinician")
  end

  it "still downgrades a normal paid subscriber on subscription.deleted" do
    payer = FactoryBot.create(:user, plan_type: "pro", stripe_customer_id: "cus_payer")
    stub_deleted_event("cus_payer")
    allow(UserMailer).to receive(:subscription_canceled_email).and_return(double(deliver_later: true))

    post_webhook("{}", header_with_signature)

    expect(payer.reload.plan_type).to eq("free")
  end
end
