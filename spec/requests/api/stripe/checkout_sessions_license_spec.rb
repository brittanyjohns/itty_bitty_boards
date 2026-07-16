require "rails_helper"

# One-time 5-Year license Checkout Session creation (mode: "payment"). Companion
# to checkout_sessions_topup_spec.rb (top-up packs) and checkout_sessions_spec.rb
# (subscriptions).
RSpec.describe "POST /api/stripe/checkout_sessions/license", type: :request do
  let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_lic") }

  before do
    # Resolved from ENV at request time (not a frozen constant), so ENV works.
    ENV["STRIPE_PRICE_BASIC_5YR"] = "price_basic_5yr_test"
    ENV["STRIPE_PRICE_PRO_5YR"] = "price_pro_5yr_test"
  end

  after do
    ENV.delete("STRIPE_PRICE_BASIC_5YR")
    ENV.delete("STRIPE_PRICE_PRO_5YR")
  end

  it "creates a one-time payment session for basic_5yr with license metadata" do
    captured = nil
    expect(Stripe::Checkout::Session).to receive(:create) do |params|
      captured = params
      OpenStruct.new(url: "https://checkout.stripe.com/c/pay/cs_lic_basic")
    end

    post "/api/stripe/checkout_sessions/license",
         params: { plan_key: "basic_5yr" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["url"]).to match(%r{checkout\.stripe\.com})

    expect(captured[:mode]).to eq("payment")
    expect(captured[:customer]).to eq("cus_lic")
    expect(captured[:line_items]).to eq([{ price: "price_basic_5yr_test", quantity: 1 }])
    expect(captured[:allow_promotion_codes]).to be(true)
    expect(captured[:metadata][:kind]).to eq("license")
    expect(captured[:metadata][:plan_type]).to eq("basic_5yr")
    expect(captured[:metadata][:license_years]).to eq(5)
    expect(captured[:metadata][:monthly_credits]).to eq(400)
    expect(captured[:metadata][:user_id]).to eq(user.id)
    # Regression guard: payment_method_collection is invalid on mode=payment.
    expect(captured).not_to have_key(:payment_method_collection)
  end

  it "creates a one-time payment session for pro_5yr with the Pro price + credits" do
    captured = nil
    allow(Stripe::Checkout::Session).to receive(:create) do |params|
      captured = params
      OpenStruct.new(url: "https://checkout.stripe.com/c/pay/cs_lic_pro")
    end

    post "/api/stripe/checkout_sessions/license",
         params: { plan_key: "pro_5yr" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(captured[:line_items]).to eq([{ price: "price_pro_5yr_test", quantity: 1 }])
    expect(captured[:metadata][:plan_type]).to eq("pro_5yr")
    expect(captured[:metadata][:monthly_credits]).to eq(1500)
    expect(user.reload.paid_plan_type).to eq("pro_5yr")
  end

  it "400s for an unknown/unconfigured plan_key" do
    post "/api/stripe/checkout_sessions/license",
         params: { plan_key: "gold_10yr" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:bad_request)
  end
end
