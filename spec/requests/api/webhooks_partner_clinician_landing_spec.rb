require "rails_helper"

# Part 3 (partner trial landing path): when a partner_pro no-card trial lapses,
# Stripe fires customer.subscription.deleted. Instead of dumping the partner on
# Free, handle_subscription_deleted lands them on a free, auto-approved
# `clinician` account (content retained). Partner Pro itself is unchanged.
RSpec.describe "POST /api/webhooks — partner trial → clinician landing", type: :request do
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

  it "lands a lapsed partner_pro trial on an auto-approved clinician account (not Free)" do
    partner = FactoryBot.create(:user, plan_type: "partner_pro", role: "partner", stripe_customer_id: "cus_partner")
    partner.update_columns(stripe_subscription_id: "sub_partner")
    stub_deleted_event("cus_partner")

    expect(UserMailer).not_to receive(:subscription_canceled_email)

    post_webhook("{}", header_with_signature)

    expect(response).to have_http_status(:ok)
    partner.reload
    expect(partner.plan_type).to eq("clinician")
    expect(partner.paid_plan?).to be(true)
    expect(partner.stripe_subscription_id).to be_nil
    expect(partner.plan_credits_balance).to eq(400)
    expect(partner.settings["paid_communicator_limit"]).to eq(2)

    app = partner.clinician_applications.approved.first
    expect(app).to be_present
    expect(app.status).to eq("approved")
  end

  it "is a no-op for an already-clinician user on webhook re-delivery" do
    already = FactoryBot.create(:user, plan_type: "clinician", stripe_customer_id: "cus_already")
    already.clinician_applications.create!(full_name: "X", credential_type: "other", status: "approved", reviewed_at: Time.current)
    stub_deleted_event("cus_already")

    expect {
      post_webhook("{}", header_with_signature)
    }.not_to change { already.reload.clinician_applications.count }
    expect(already.plan_type).to eq("clinician")
  end

  it "still downgrades a normal (non-partner) paid subscriber to Free on subscription.deleted" do
    payer = FactoryBot.create(:user, plan_type: "pro", stripe_customer_id: "cus_payer")
    stub_deleted_event("cus_payer")
    allow(UserMailer).to receive(:subscription_canceled_email).and_return(double(deliver_later: true))

    post_webhook("{}", header_with_signature)

    expect(payer.reload.plan_type).to eq("free")
  end
end
