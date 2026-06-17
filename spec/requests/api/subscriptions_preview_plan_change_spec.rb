require "rails_helper"

RSpec.describe "POST /api/subscriptions/preview_plan_change", type: :request do
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
    OpenStruct.new(id: "price_pro", unit_amount: 999, metadata: { "plan_type" => "pro" },
                   recurring: OpenStruct.new(interval: "month"))
  end

  let(:upcoming_invoice) do
    OpenStruct.new(amount_due: 500, currency: "usd")
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
    post "/api/subscriptions/preview_plan_change", params: params, headers: auth_headers(user)
  end

  before { stub_price_ids }

  context "with a valid plan switch" do
    before do
      stub_subscription_list([active_sub])
      allow(Stripe::Invoice).to receive(:upcoming).and_return(upcoming_invoice)
      allow(Stripe::Price).to receive(:retrieve).with("price_pro").and_return(new_price)
    end

    it "returns proration details from Stripe" do
      do_post

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["current_plan"]).to eq("basic")
      expect(body["new_plan"]).to eq("pro")
      expect(body["proration_amount_cents"]).to eq(500)
      expect(body["new_recurring_amount_cents"]).to eq(999)
      expect(body["billing_interval"]).to eq("monthly")
      expect(body["currency"]).to eq("usd")
      expect(body["discount"]).to be_nil
    end

    it "calls Invoice.upcoming with subscription_details params" do
      expect(Stripe::Invoice).to receive(:upcoming) do |params|
        expect(params[:customer]).to eq("cus_existing")
        expect(params[:subscription]).to eq("sub_active")
        expect(params[:subscription_details][:items]).to eq([{ id: "si_123", price: "price_pro" }])
        expect(params[:subscription_details][:proration_behavior]).to eq("create_prorations")
        expect(params).not_to have_key(:subscription_items)
        upcoming_invoice
      end

      do_post
    end
  end

  context "with a promo code" do
    let(:promo) { OpenStruct.new(id: "promo_summer", coupon: OpenStruct.new(percent_off: 20, amount_off: nil)) }

    before do
      stub_subscription_list([active_sub])
      allow(Stripe::PromotionCode).to receive(:list)
        .with(code: "SUMMER20", active: true, limit: 1)
        .and_return(OpenStruct.new(data: [promo]))
      allow(Stripe::Price).to receive(:retrieve).with("price_pro").and_return(new_price)
    end

    it "includes discount details and passes promo to Invoice.upcoming" do
      captured = nil
      allow(Stripe::Invoice).to receive(:upcoming) do |params|
        captured = params
        upcoming_invoice
      end

      do_post(plan_key: "pro", promo_code: " SUMMER20 ")

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["discount"]["code"]).to eq("SUMMER20")
      expect(body["discount"]["percent_off"]).to eq(20)
      expect(captured[:subscription_details][:discounts]).to eq([{ promotion_code: "promo_summer" }])
    end
  end

  context "yearly plan" do
    let(:yearly_price) do
      OpenStruct.new(id: "price_pro_year", unit_amount: 9999, metadata: { "plan_type" => "pro" },
                     recurring: OpenStruct.new(interval: "year"))
    end

    before do
      stub_subscription_list([active_sub])
      allow(Stripe::Invoice).to receive(:upcoming).and_return(upcoming_invoice)
      allow(Stripe::Price).to receive(:retrieve).with("price_pro_year").and_return(yearly_price)
    end

    it "reports billing_interval as yearly" do
      do_post(plan_key: "pro_yearly")

      body = JSON.parse(response.body)
      expect(body["billing_interval"]).to eq("yearly")
    end
  end

  context "same plan as current" do
    before { stub_subscription_list([active_sub]) }

    it "returns 422" do
      do_post(plan_key: "basic")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Already on this plan")
    end
  end

  context "unknown plan_key" do
    it "returns 422" do
      do_post(plan_key: "nonsense")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Unknown or unsupported plan")
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
      allow(Stripe::Invoice).to receive(:upcoming).and_return(upcoming_invoice)
      allow(Stripe::Price).to receive(:retrieve).with("price_pro").and_return(new_price)
    end

    it "is eligible for preview" do
      do_post

      expect(response).to have_http_status(:ok)
    end
  end

  context "when Stripe raises" do
    before { stub_subscription_list([active_sub]) }

    it "returns 400 with a generic message" do
      allow(Stripe::Invoice).to receive(:upcoming)
        .and_raise(Stripe::InvalidRequestError.new("bad params", nil))

      do_post

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("Failed to preview plan change")
    end
  end
end
