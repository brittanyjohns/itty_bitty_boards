require "rails_helper"

# Billing portal for everyone (frictionless paid signup work): lazy
# Stripe-customer creation for accounts that don't have one yet, and a
# rescue so Stripe failures return 400 instead of 500.
RSpec.describe "POST /api/subscriptions/billing_portal", type: :request do
  let(:portal_session) { OpenStruct.new(url: "https://billing.stripe.com/p/session_test") }

  def do_post(user)
    post "/api/subscriptions/billing_portal", headers: auth_headers(user)
  end

  context "when the user already has a Stripe customer" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_existing") }

    it "creates a portal session without creating a customer" do
      allow(User).to receive(:create_stripe_customer)
      captured = nil
      expect(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["url"]).to eq(portal_session.url)
      expect(captured[:customer]).to eq("cus_existing")
      expect(User).not_to have_received(:create_stripe_customer)
    end
  end

  context "when the user has no Stripe customer" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: nil) }

    it "lazily creates one, persists it, and opens the portal" do
      expect(User).to receive(:create_stripe_customer).with(user.email).once.and_return("cus_lazy")
      captured = nil
      expect(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post(user)

      expect(response).to have_http_status(:ok)
      expect(user.reload.stripe_customer_id).to eq("cus_lazy")
      expect(captured[:customer]).to eq("cus_lazy")
    end
  end

  context "when Stripe raises" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_existing") }

    it "returns 400 with a generic message, not 500" do
      allow(Stripe::BillingPortal::Session).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("No configuration provided", nil))

      do_post(user)

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Failed to create billing portal session")
      expect(body["error"]).not_to include("configuration")
    end
  end

  context "with STRIPE_PORTAL_CONFIG_ID set" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_existing") }

    around do |example|
      ENV["STRIPE_PORTAL_CONFIG_ID"] = "bpc_test_config"
      example.run
    ensure
      ENV.delete("STRIPE_PORTAL_CONFIG_ID")
    end

    it "passes it as configuration" do
      captured = nil
      expect(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post(user)

      expect(captured[:configuration]).to eq("bpc_test_config")
    end
  end
end
