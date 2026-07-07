require "rails_helper"

# Covers the payment-failed email fired from the Stripe invoice.payment_failed
# webhook (#220). The email must fire exactly once on the active -> past_due
# transition, and NOT again on a redelivery of the same event or a subsequent
# dunning retry while the user is already past_due.
# See API::WebhooksController#handle_invoice_payment_failed.
RSpec.describe "POST /api/webhooks (payment failed email)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_payment_failed",
      plan_type: "basic",
      plan_status: "active")
  end

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  # Minimal subscription the handler retrieves via Stripe::Subscription.retrieve.
  def build_subscription(status: "past_due", customer: user.stripe_customer_id, id: "sub_pf")
    OpenStruct.new(id: id, customer: customer, status: status)
  end

  # invoice.payment_failed carries only the subscription id here; the handler
  # then retrieves the subscription and resolves the user from its customer.
  def build_invoice(subscription_id: "sub_pf")
    OpenStruct.new(subscription: subscription_id)
  end

  def stub_payment_failed(subscription: build_subscription, event_id: "evt_pf")
    allow(Stripe::Subscription).to receive(:retrieve).with(subscription.id).and_return(subscription)
    stub_event(build_invoice(subscription_id: subscription.id),
      type: "invoice.payment_failed", event_id: event_id)
  end

  describe "active -> past_due transition" do
    it "flips the user to past_due and queues the payment_failed email once" do
      mail = double(deliver_later: true)
      allow(UserMailer).to receive(:payment_failed_email).and_return(mail)

      stub_payment_failed
      post_webhook("{}", header_with_signature)

      expect(user.reload.plan_status).to eq("past_due")
      expect(UserMailer).to have_received(:payment_failed_email).with(
        an_object_having_attributes(id: user.id),
      ).once
    end
  end

  describe "idempotency" do
    it "does NOT re-send when the user is already past_due (a later retry)" do
      user.update!(plan_status: "past_due")
      mail = double(deliver_later: true)
      allow(UserMailer).to receive(:payment_failed_email).and_return(mail)

      stub_payment_failed
      post_webhook("{}", header_with_signature)

      expect(user.reload.plan_status).to eq("past_due")
      expect(UserMailer).not_to have_received(:payment_failed_email)
    end

    it "sends only once across two deliveries of the failure" do
      mail = double(deliver_later: true)
      allow(UserMailer).to receive(:payment_failed_email).and_return(mail)

      # First failure: active -> past_due, email fires.
      stub_payment_failed(event_id: "evt_pf_1")
      post_webhook("{}", header_with_signature)

      # Redelivery / next retry: already past_due, no second email.
      stub_payment_failed(event_id: "evt_pf_2")
      post_webhook("{}", header_with_signature)

      expect(UserMailer).to have_received(:payment_failed_email).once
    end
  end

  describe "admins" do
    it "does not touch plan_status or email admin users" do
      user.update!(role: "admin")
      allow(UserMailer).to receive(:payment_failed_email)

      stub_payment_failed
      post_webhook("{}", header_with_signature)

      expect(user.reload.plan_status).to eq("active")
      expect(UserMailer).not_to have_received(:payment_failed_email)
    end
  end
end
