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

  def stub_customer(default_payment_method:)
    allow(Stripe::Customer).to receive(:retrieve).and_return(
      OpenStruct.new(invoice_settings: OpenStruct.new(default_payment_method: default_payment_method)),
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
end
