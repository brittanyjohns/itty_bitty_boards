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
  def build_invoice(subscription_id: "sub_pf", payment_intent: nil)
    OpenStruct.new(subscription: subscription_id, payment_intent: payment_intent)
  end

  def stub_payment_failed(subscription: build_subscription, event_id: "evt_pf", payment_intent: nil)
    allow(Stripe::Subscription).to receive(:retrieve).with(subscription.id).and_return(subscription)
    stub_event(build_invoice(subscription_id: subscription.id, payment_intent: payment_intent),
      type: "invoice.payment_failed", event_id: event_id)
  end

  # The failure detail lives on the invoice's PaymentIntent.
  def stub_payment_intent(id, code: nil, decline_code: nil, error: :build)
    error = OpenStruct.new(code: code, decline_code: decline_code, message: "Your card was declined.") if error == :build
    allow(Stripe::PaymentIntent).to receive(:retrieve).with(id)
      .and_return(OpenStruct.new(id: id, last_payment_error: error))
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

  describe "capturing the decline reason (#826)" do
    before do
      allow(UserMailer).to receive(:payment_failed_email).and_return(double(deliver_later: true))
    end

    it "persists the mapped reason from the PaymentIntent's last_payment_error" do
      stub_payment_intent("pi_pf", code: "card_declined", decline_code: "insufficient_funds")
      stub_payment_failed(payment_intent: "pi_pf")
      post_webhook("{}", header_with_signature)

      failure = user.reload.settings[User::PAYMENT_FAILURE_KEY]
      expect(failure["reason"]).to eq("insufficient_funds")
      expect(Time.zone.parse(failure["at"])).to be_within(1.minute).of(Time.current)
    end

    it "never stores Stripe's raw message" do
      stub_payment_intent("pi_pf", code: "card_declined", decline_code: "insufficient_funds")
      stub_payment_failed(payment_intent: "pi_pf")
      post_webhook("{}", header_with_signature)

      expect(user.reload.settings[User::PAYMENT_FAILURE_KEY].values.join(" "))
        .not_to include("Your card was declined")
    end

    it "does not surface a fraud decline" do
      stub_payment_intent("pi_pf", code: "card_declined", decline_code: "stolen_card")
      stub_payment_failed(payment_intent: "pi_pf")
      post_webhook("{}", header_with_signature)

      expect(user.reload.settings[User::PAYMENT_FAILURE_KEY]["reason"]).to eq("generic")
    end

    it "still marks the user past_due when the PaymentIntent lookup blows up" do
      allow(Stripe::PaymentIntent).to receive(:retrieve).and_raise(StandardError, "stripe down")
      stub_payment_failed(payment_intent: "pi_pf")
      post_webhook("{}", header_with_signature)

      expect(user.reload.plan_status).to eq("past_due")
      expect(user.settings[User::PAYMENT_FAILURE_KEY]["reason"]).to eq("generic")
    end

    it "records generic when the invoice carries no PaymentIntent" do
      stub_payment_failed
      post_webhook("{}", header_with_signature)

      expect(user.reload.settings[User::PAYMENT_FAILURE_KEY]["reason"]).to eq("generic")
    end

    it "refreshes the reason on a later dunning retry" do
      stub_payment_intent("pi_1", code: "card_declined", decline_code: "insufficient_funds")
      stub_payment_failed(payment_intent: "pi_1", event_id: "evt_pf_1")
      post_webhook("{}", header_with_signature)

      stub_payment_intent("pi_2", code: "expired_card")
      stub_payment_failed(payment_intent: "pi_2", event_id: "evt_pf_2")
      post_webhook("{}", header_with_signature)

      expect(user.reload.settings[User::PAYMENT_FAILURE_KEY]["reason"]).to eq("expired_card")
    end
  end
end
