require "rails_helper"

# Covers the cancellation-confirmation email fired from the Stripe
# customer.subscription.deleted webhook (#196). Enqueued for non-admin users
# after apply_free_plan downgrades them to Free; admins never receive it.
# See API::WebhooksController#handle_subscription_deleted.
RSpec.describe "POST /api/webhooks (subscription canceled email)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_canceled_email",
      plan_type: "pro",
      plan_status: "active")
  end

  before do
    ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy"
    # Don't depend on analytics env in this spec.
    allow(PosthogService).to receive(:capture_for_user)
  end

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def build_subscription(customer: user.stripe_customer_id, id: "sub_cancel")
    OpenStruct.new(id: id, customer: customer, status: "canceled", cancellation_details: nil)
  end

  it "downgrades to free and queues the cancellation email for a non-admin" do
    mail = double(deliver_later: true)
    allow(UserMailer).to receive(:subscription_canceled_email).and_return(mail)

    stub_event(build_subscription, type: "customer.subscription.deleted")
    post_webhook("{}", header_with_signature)

    expect(user.reload.plan_type).to eq("free")
    expect(UserMailer).to have_received(:subscription_canceled_email).with(
      an_object_having_attributes(id: user.id),
    ).once
  end

  it "does NOT email admins" do
    user.update!(role: "admin")
    allow(UserMailer).to receive(:subscription_canceled_email)

    stub_event(build_subscription, type: "customer.subscription.deleted")
    post_webhook("{}", header_with_signature)

    expect(UserMailer).not_to have_received(:subscription_canceled_email)
  end

  it "does not email when no user resolves for the subscription" do
    allow(UserMailer).to receive(:subscription_canceled_email)

    stub_event(build_subscription(customer: "cus_nobody"), type: "customer.subscription.deleted")
    # No Stripe::Customer fallback match either.
    allow(Stripe::Customer).to receive(:retrieve).and_return(OpenStruct.new(email: nil))
    post_webhook("{}", header_with_signature)

    expect(UserMailer).not_to have_received(:subscription_canceled_email)
  end
end
