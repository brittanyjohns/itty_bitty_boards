require "rails_helper"

# Promo-aware one-click plan switch for existing subscribers (issue #308).
# Opens a Stripe Customer-portal deep link (flow_data.subscription_update_confirm)
# that pre-selects the target price and pre-applies the promotion code.
RSpec.describe "POST /api/subscriptions/change_plan_portal_session", type: :request do
  let(:portal_session) { OpenStruct.new(url: "https://billing.stripe.com/p/session_test") }
  let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_existing") }

  let(:sub_item) { OpenStruct.new(id: "si_123") }
  let(:active_sub) do
    OpenStruct.new(id: "sub_active", status: "active",
                   items: OpenStruct.new(data: [sub_item]))
  end

  def stub_price_ids
    stub_const(
      "API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS",
      { "free" => nil, "basic_yearly" => "price_basic_year", "pro" => "price_pro" },
    )
  end

  def stub_subscription_list(subscriptions)
    allow(Stripe::Subscription).to receive(:list)
      .and_return(OpenStruct.new(data: subscriptions))
  end

  def do_post(params = { plan_key: "basic_yearly" })
    post "/api/subscriptions/change_plan_portal_session", params: params, headers: auth_headers(user)
  end

  before { stub_price_ids }

  context "with a valid plan and an active subscription" do
    it "opens a subscription_update_confirm portal session for the user's item" do
      stub_subscription_list([active_sub])
      captured = nil
      expect(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["url"]).to eq(portal_session.url)
      expect(captured[:customer]).to eq("cus_existing")
      expect(captured[:flow_data][:type]).to eq("subscription_update_confirm")
      confirm = captured[:flow_data][:subscription_update_confirm]
      expect(confirm[:subscription]).to eq("sub_active")
      expect(confirm[:items]).to eq([{ id: "si_123", price: "price_basic_year", quantity: 1 }])
      expect(confirm).not_to have_key(:discounts)
    end
  end

  context "with a promo code" do
    it "looks it up and pre-applies the promotion code to the flow" do
      stub_subscription_list([active_sub])
      promo = OpenStruct.new(id: "promo_founding")
      expect(Stripe::PromotionCode).to receive(:list)
        .with(code: "FOUNDING", active: true, limit: 1)
        .and_return(OpenStruct.new(data: [promo]))

      captured = nil
      allow(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post(plan_key: "basic_yearly", promo_code: " FOUNDING ")

      expect(response).to have_http_status(:ok)
      expect(captured[:flow_data][:subscription_update_confirm][:discounts])
        .to eq([{ promotion_code: "promo_founding" }])
    end

    it "silently skips an unknown promo code (no discount)" do
      stub_subscription_list([active_sub])
      allow(Stripe::PromotionCode).to receive(:list)
        .and_return(OpenStruct.new(data: []))

      captured = nil
      allow(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post(plan_key: "basic_yearly", promo_code: "NOPE")

      expect(response).to have_http_status(:ok)
      expect(captured[:flow_data][:subscription_update_confirm]).not_to have_key(:discounts)
    end
  end

  context "trialing subscription (no-card reverse trial)" do
    it "is eligible for the switch" do
      trialing = OpenStruct.new(id: "sub_trial", status: "trialing",
                                items: OpenStruct.new(data: [sub_item]))
      stub_subscription_list([trialing])
      captured = nil
      allow(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post

      expect(response).to have_http_status(:ok)
      expect(captured[:flow_data][:subscription_update_confirm][:subscription]).to eq("sub_trial")
    end
  end

  context "unknown plan_key" do
    it "returns 422 without touching Stripe" do
      expect(Stripe::BillingPortal::Session).not_to receive(:create)

      do_post(plan_key: "nonsense")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Unknown or unsupported plan")
    end
  end

  context "free plan_key (nil price)" do
    it "returns 422 (downgrades to free go through cancellation, not here)" do
      expect(Stripe::BillingPortal::Session).not_to receive(:create)

      do_post(plan_key: "free")

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  context "user with no Stripe customer" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: nil) }

    it "returns 422 — they belong in checkout" do
      expect(Stripe::Subscription).not_to receive(:list)

      do_post

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("No active subscription to change")
    end
  end

  context "user with a customer but no active subscription" do
    it "returns 422" do
      stub_subscription_list([OpenStruct.new(id: "sub_old", status: "canceled",
                                             items: OpenStruct.new(data: [sub_item]))])

      do_post

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("No active subscription to change")
    end
  end

  context "with STRIPE_PORTAL_CONFIG_ID set" do
    around do |example|
      ENV["STRIPE_PORTAL_CONFIG_ID"] = "bpc_test_config"
      example.run
    ensure
      ENV.delete("STRIPE_PORTAL_CONFIG_ID")
    end

    it "passes it as configuration" do
      stub_subscription_list([active_sub])
      captured = nil
      allow(Stripe::BillingPortal::Session).to receive(:create) do |params|
        captured = params
        portal_session
      end

      do_post

      expect(captured[:configuration]).to eq("bpc_test_config")
    end
  end

  context "when Stripe raises" do
    it "returns 400 with a generic message, not 500" do
      stub_subscription_list([active_sub])
      allow(Stripe::BillingPortal::Session).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("No flow config", nil))

      do_post

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Failed to create plan change session")
      expect(body["error"]).not_to include("flow")
    end
  end
end
