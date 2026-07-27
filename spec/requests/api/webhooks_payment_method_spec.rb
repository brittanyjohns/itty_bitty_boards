require "rails_helper"

# Covers settings["has_payment_method"] — the flag behind the trial banner's
# "add a payment method" CTA (see drafts/2026-07-27-trial-banner-payment-method-design.md).
RSpec.describe "POST /api/webhooks (has_payment_method)", type: :request do
  include StripeHelpers

  let_it_be(:user, reload: true) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_pm_user",
      plan_type: "basic",
      plan_status: "trialing")
  end

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def build_metadata(hash)
    Class.new do
      def initialize(h) = @h = h.transform_keys(&:to_s)
      def [](k) = @h[k.to_s]
      def presence = @h.presence
      def to_h = @h
    end.new(hash)
  end

  def build_price(plan_type: "basic", monthly_credits: 400, id: "price_basic")
    OpenStruct.new(
      id: id,
      metadata: build_metadata("plan_type" => plan_type, "monthly_credits" => monthly_credits.to_s),
    )
  end

  def build_subscription(default_payment_method: nil, status: "trialing")
    OpenStruct.new(
      id: "sub_#{SecureRandom.hex(3)}",
      customer: user.stripe_customer_id,
      status: status,
      current_period_end: 14.days.from_now.to_i,
      trial_end: 14.days.from_now.to_i,
      default_payment_method: default_payment_method,
      items: OpenStruct.new(data: [OpenStruct.new(price: build_price, quantity: 1)]),
    )
  end

  def stub_customer(default_payment_method:, default_source: nil)
    allow(Stripe::Customer).to receive(:retrieve).and_return(
      OpenStruct.new(
        invoice_settings: OpenStruct.new(default_payment_method: default_payment_method),
        default_source: default_source,
      ),
    )
  end

  it "records false for a no-card reverse trial" do
    stub_customer(default_payment_method: nil)
    stub_event(build_subscription, type: "customer.subscription.updated")

    post_webhook("{}", header_with_signature)

    expect(user.reload.settings["has_payment_method"]).to eq(false)
  end

  it "records true when the subscription carries a default payment method" do
    stub_event(build_subscription(default_payment_method: "pm_card_123"),
               type: "customer.subscription.updated")

    post_webhook("{}", header_with_signature)

    expect(user.reload.settings["has_payment_method"]).to eq(true)
  end

  it "falls back to the customer's default payment method (portal writes it there)" do
    stub_customer(default_payment_method: "pm_from_portal")
    stub_event(build_subscription, type: "customer.subscription.updated")

    post_webhook("{}", header_with_signature)

    expect(user.reload.settings["has_payment_method"]).to eq(true)
  end

  it "keeps the previous value and does not 500 when Stripe raises" do
    user.update!(settings: user.settings.merge("has_payment_method" => true))
    allow(Stripe::Customer).to receive(:retrieve).and_raise(Stripe::APIError.new("boom"))
    stub_event(build_subscription, type: "customer.subscription.updated")

    post_webhook("{}", header_with_signature)

    expect(response).to have_http_status(:ok)
    expect(user.reload.settings["has_payment_method"]).to eq(true)
  end

  it "records true for a customer whose only card is a legacy default_source" do
    stub_customer(default_payment_method: nil, default_source: "card_legacy")
    stub_event(build_subscription, type: "customer.subscription.updated")

    post_webhook("{}", header_with_signature)

    expect(user.reload.settings["has_payment_method"]).to eq(true)
  end

  it "does not call Stripe::Customer.retrieve and leaves has_payment_method unchanged for a non-trialing upsert" do
    user.update!(settings: user.settings.merge("has_payment_method" => true))
    expect(Stripe::Customer).not_to receive(:retrieve)
    stub_event(build_subscription(status: "active"), type: "customer.subscription.updated")

    post_webhook("{}", header_with_signature)

    expect(response).to have_http_status(:ok)
    expect(user.reload.settings["has_payment_method"]).to eq(true)
  end

  describe "payment_method.attached" do
    def build_payment_method(customer: user.stripe_customer_id)
      OpenStruct.new(id: "pm_#{SecureRandom.hex(3)}", customer: customer)
    end

    it "flips has_payment_method to true for the matching user" do
      user.update!(settings: user.settings.merge("has_payment_method" => false))
      stub_event(build_payment_method, type: "payment_method.attached")

      post_webhook("{}", header_with_signature)

      expect(response).to have_http_status(:ok)
      expect(user.reload.settings["has_payment_method"]).to eq(true)
    end

    it "is a no-op for an unknown customer and still returns 200" do
      stub_event(build_payment_method(customer: "cus_nobody"), type: "payment_method.attached")

      post_webhook("{}", header_with_signature)

      expect(response).to have_http_status(:ok)
    end
  end
end
