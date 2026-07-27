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
    # Pins that the Stripe error was swallowed by payment_method_on_file?'s own
    # local rescue, not by handle_subscription_upsert's outer rescue. If the
    # local rescue were removed, the error would propagate to the outer rescue,
    # user.save! would never run, and this would fail (trial_ends_at would be
    # nil) even though has_payment_method and the 200 response above would
    # still look correct.
    expect(user.reload.settings["trial_ends_at"]).to be_present
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

    it "resolves the customer id from an expanded customer object" do
      user.update!(settings: user.settings.merge("has_payment_method" => false))
      expanded_customer = OpenStruct.new(id: user.stripe_customer_id)
      stub_event(build_payment_method(customer: expanded_customer), type: "payment_method.attached")

      post_webhook("{}", header_with_signature)

      expect(response).to have_http_status(:ok)
      expect(user.reload.settings["has_payment_method"]).to eq(true)
    end

    it "is a no-op and does not flip an unrelated user's flag when the customer id is blank" do
      stranger = FactoryBot.create(:user, stripe_customer_id: nil)
      stranger.update!(settings: stranger.settings.merge("has_payment_method" => false))
      stub_event(build_payment_method(customer: nil), type: "payment_method.attached")

      post_webhook("{}", header_with_signature)

      expect(response).to have_http_status(:ok)
      expect(stranger.reload.settings["has_payment_method"]).to eq(false)
    end

    # Fix B: the flag is only meaningful for a trialist (it drives the trial
    # banner's CTA), so a non-trial attach — e.g. a credit top-up purchase's
    # payment method, which is never a subscription/customer default anywhere
    # — must write nothing. Writing `true` here would silently disable the
    # nudge for the exact reverse-trial cohort this feature exists to catch.
    it "does not write has_payment_method for a non-trialing user" do
      non_trialist = FactoryBot.create(:user,
        stripe_customer_id: "cus_pm_non_trial",
        plan_type: "basic",
        plan_status: "active")
      non_trialist.update!(settings: non_trialist.settings.merge("has_payment_method" => false))
      stub_event(build_payment_method(customer: "cus_pm_non_trial"), type: "payment_method.attached")

      post_webhook("{}", header_with_signature)

      expect(response).to have_http_status(:ok)
      expect(non_trialist.reload.settings["has_payment_method"]).to eq(false)
    end
  end
end
