require "rails_helper"

RSpec.describe "POST /api/subscriptions/change_plan", type: :request do
  let(:user) { FactoryBot.create(:user, plan_type: "basic", stripe_customer_id: "cus_existing") }

  let(:current_price) do
    OpenStruct.new(id: "price_basic", metadata: { "plan_type" => "basic" },
                   recurring: OpenStruct.new(interval: "month"))
  end
  let(:sub_item) { OpenStruct.new(id: "si_123", price: current_price) }
  let(:active_sub) do
    OpenStruct.new(id: "sub_active", status: "active", current_period_end: 1760551812,
                   items: OpenStruct.new(data: [sub_item]))
  end

  let(:new_price) do
    OpenStruct.new(id: "price_pro", metadata: { "plan_type" => "pro" },
                   recurring: OpenStruct.new(interval: "month"))
  end

  let(:updated_sub) do
    OpenStruct.new(id: "sub_active", status: "active", current_period_end: 1760551812,
                   items: OpenStruct.new(data: [OpenStruct.new(id: "si_123", price: new_price)]))
  end

  def stub_price_ids
    stub_const(
      "API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS",
      { "free" => nil, "basic" => "price_basic", "pro" => "price_pro",
        "basic_yearly" => "price_basic_year", "pro_yearly" => "price_pro_year" },
    )
  end

  def stub_subscription_list(subscriptions)
    allow(Stripe::Subscription).to receive(:list)
      .and_return(OpenStruct.new(data: subscriptions))
  end

  def do_post(params = { plan_key: "pro" })
    post "/api/subscriptions/change_plan", params: params, headers: auth_headers(user)
  end

  before { stub_price_ids }

  context "with a valid plan switch" do
    before { stub_subscription_list([active_sub]) }

    it "updates the subscription and returns the new plan" do
      expect(Stripe::Subscription).to receive(:update)
        .with("sub_active", hash_including(
          items: [{ id: "si_123", price: "price_pro" }],
          proration_behavior: "create_prorations",
        ))
        .and_return(updated_sub)

      do_post

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["plan"]).to eq("pro")
      expect(body["status"]).to eq("active")
      expect(body["billing_interval"]).to eq("monthly")
      expect(body["current_period_end"]).to be_present
    end

    it "does not include discounts when no promo given" do
      captured = nil
      allow(Stripe::Subscription).to receive(:update) do |_id, params|
        captured = params
        updated_sub
      end

      do_post

      expect(captured).not_to have_key(:discounts)
    end
  end

  context "with a promo code" do
    let(:promo) { OpenStruct.new(id: "promo_founding") }

    before do
      stub_subscription_list([active_sub])
      allow(Stripe::PromotionCode).to receive(:list)
        .with(code: "FOUNDING", active: true, limit: 1)
        .and_return(OpenStruct.new(data: [promo]))
    end

    it "applies the promotion code to the subscription update" do
      captured = nil
      allow(Stripe::Subscription).to receive(:update) do |_id, params|
        captured = params
        updated_sub
      end

      do_post(plan_key: "pro", promo_code: " FOUNDING ")

      expect(response).to have_http_status(:ok)
      expect(captured[:discounts]).to eq([{ promotion_code: "promo_founding" }])
    end

    it "silently skips an unknown promo code" do
      allow(Stripe::PromotionCode).to receive(:list)
        .and_return(OpenStruct.new(data: []))

      captured = nil
      allow(Stripe::Subscription).to receive(:update) do |_id, params|
        captured = params
        updated_sub
      end

      do_post(plan_key: "pro", promo_code: "NOPE")

      expect(response).to have_http_status(:ok)
      expect(captured).not_to have_key(:discounts)
    end
  end

  context "yearly plan switch" do
    let(:yearly_price) do
      OpenStruct.new(id: "price_pro_year", metadata: { "plan_type" => "pro" },
                     recurring: OpenStruct.new(interval: "year"))
    end
    let(:yearly_updated_sub) do
      OpenStruct.new(id: "sub_active", status: "active", current_period_end: 1792087812,
                     items: OpenStruct.new(data: [OpenStruct.new(id: "si_123", price: yearly_price)]))
    end

    before do
      stub_subscription_list([active_sub])
      allow(Stripe::Subscription).to receive(:update).and_return(yearly_updated_sub)
    end

    it "reports billing_interval as yearly" do
      do_post(plan_key: "pro_yearly")

      body = JSON.parse(response.body)
      expect(body["billing_interval"]).to eq("yearly")
    end
  end

  context "same plan as current" do
    before { stub_subscription_list([active_sub]) }

    it "returns 422 without touching Stripe" do
      expect(Stripe::Subscription).not_to receive(:update)

      do_post(plan_key: "basic")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Already on this plan")
    end
  end

  context "unknown plan_key" do
    it "returns 422" do
      expect(Stripe::Subscription).not_to receive(:update)

      do_post(plan_key: "nonsense")

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  context "free plan_key" do
    it "returns 422" do
      do_post(plan_key: "free")

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  context "no Stripe customer" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: nil) }

    it "returns 422" do
      do_post

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("No active subscription to change")
    end
  end

  context "no active subscription" do
    before do
      stub_subscription_list([OpenStruct.new(id: "sub_old", status: "canceled",
                                             items: OpenStruct.new(data: [sub_item]))])
    end

    it "returns 422" do
      do_post

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  context "trialing subscription" do
    let(:trialing_sub) do
      OpenStruct.new(id: "sub_trial", status: "trialing", current_period_end: 1760551812,
                     items: OpenStruct.new(data: [sub_item]))
    end

    before do
      stub_subscription_list([trialing_sub])
      allow(Stripe::Subscription).to receive(:update).and_return(updated_sub)
    end

    it "is eligible for plan switch" do
      do_post

      expect(response).to have_http_status(:ok)
    end
  end

  context "when Stripe card is declined" do
    before do
      stub_subscription_list([active_sub])
      allow(Stripe::Subscription).to receive(:update)
        .and_raise(Stripe::CardError.new("Your card was declined.", nil, code: "card_declined"))
    end

    it "returns 402 with payment_failed error" do
      do_post

      expect(response).to have_http_status(:payment_required)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("payment_failed")
      expect(body["message"]).to include("declined")
    end
  end

  context "when Stripe raises a generic error" do
    before do
      stub_subscription_list([active_sub])
      allow(Stripe::Subscription).to receive(:update)
        .and_raise(Stripe::InvalidRequestError.new("bad request", nil))
    end

    it "returns 400 with a generic message" do
      do_post

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("Failed to change plan")
    end
  end
end
