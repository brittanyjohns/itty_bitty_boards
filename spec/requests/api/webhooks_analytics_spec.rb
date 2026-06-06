require "rails_helper"

# Server-side PostHog subscription lifecycle events (itty-bitty-frontend#307).
# Verifies the Stripe webhook fires PosthogService.capture_for_user with the
# right event + properties on each money-path transition. Gating itself is
# covered in spec/models/posthog_service_spec.rb; here we spy on the service so
# the assertions don't depend on env.
RSpec.describe "POST /api/webhooks (PostHog analytics)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_analytics_user",
      plan_type: "basic",
      plan_status: "active")
  end

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def build_metadata(hash)
    Class.new do
      def initialize(h) = (@h = h.transform_keys(&:to_s))
      def [](k) = @h[k.to_s]
      def presence; @h.presence; end
      def to_h; @h; end
    end.new(hash)
  end

  def build_price(plan_type: "basic", interval: "month", id: "price_basic")
    OpenStruct.new(
      id: id,
      metadata: build_metadata({ "plan_type" => plan_type, "monthly_credits" => "400" }),
      recurring: OpenStruct.new(interval: interval),
    )
  end

  def build_subscription(status: "active", price: build_price, trial_end: nil,
                         cancellation_details: nil, customer: user.stripe_customer_id)
    OpenStruct.new(
      id: "sub_#{SecureRandom.hex(3)}",
      customer: customer,
      status: status,
      current_period_end: 30.days.from_now.to_i,
      trial_end: trial_end&.to_i,
      cancellation_details: cancellation_details,
      items: OpenStruct.new(data: [OpenStruct.new(price: price, quantity: 1)]),
    )
  end

  describe "subscription_started (non-active → active)" do
    it "captures subscription_started with plan + billing_interval" do
      user.update!(plan_status: "trialing")
      sub = build_subscription(status: "active", price: build_price(interval: "month"))
      stub_event(sub, type: "customer.subscription.updated")

      expect(PosthogService).to receive(:capture_for_user).with(
        an_object_having_attributes(id: user.id),
        "subscription_started",
        properties: { plan: "basic", billing_interval: "monthly" },
      )

      post_webhook("{}", header_with_signature)
    end

    it "maps a yearly Stripe interval to billing_interval=yearly" do
      user.update!(plan_status: "trialing")
      sub = build_subscription(status: "active", price: build_price(interval: "year"))
      stub_event(sub, type: "customer.subscription.updated")

      expect(PosthogService).to receive(:capture_for_user).with(
        anything, "subscription_started",
        properties: hash_including(billing_interval: "yearly"),
      )

      post_webhook("{}", header_with_signature)
    end

    it "does not capture on an active → active renewal" do
      user.update!(plan_status: "active")
      sub = build_subscription(status: "active")
      stub_event(sub, type: "customer.subscription.updated")

      expect(PosthogService).not_to receive(:capture_for_user)

      post_webhook("{}", header_with_signature)
    end
  end

  describe "trial_started (subscription.created, trialing)" do
    it "captures trial_started with the plan and $set plan" do
      sub = build_subscription(status: "trialing", trial_end: 14.days.from_now)
      stub_event(sub, type: "customer.subscription.created")

      expect(PosthogService).to receive(:capture_for_user).with(
        an_object_having_attributes(id: user.id),
        "trial_started",
        properties: { plan: "basic" },
        set: { plan: "basic" },
      )

      post_webhook("{}", header_with_signature)
    end

    it "does not capture trial_started on a non-trialing create" do
      sub = build_subscription(status: "active")
      stub_event(sub, type: "customer.subscription.created")

      expect(PosthogService).not_to receive(:capture_for_user).with(
        anything, "trial_started", anything,
      )

      post_webhook("{}", header_with_signature)
    end

    it "skips admin users" do
      user.update!(role: "admin")
      sub = build_subscription(status: "trialing", trial_end: 14.days.from_now)
      stub_event(sub, type: "customer.subscription.created")

      expect(PosthogService).not_to receive(:capture_for_user)

      post_webhook("{}", header_with_signature)
    end
  end

  describe "subscription_cancelled (subscription.deleted)" do
    it "captures subscription_cancelled with the cancelled plan + reason before downgrade" do
      user.update!(plan_type: "pro", plan_status: "active")
      details = OpenStruct.new(feedback: "too_expensive", reason: "cancellation_requested")
      sub = build_subscription(status: "canceled", cancellation_details: details)
      stub_event(sub, type: "customer.subscription.deleted")

      expect(PosthogService).to receive(:capture_for_user).with(
        an_object_having_attributes(id: user.id),
        "subscription_cancelled",
        properties: { plan: "pro", reason: "too_expensive" },
      )

      post_webhook("{}", header_with_signature)
    end

    it "also records an internal subscription_canceled AnalyticsEvent" do
      user.update!(plan_type: "pro", plan_status: "active")
      allow(PosthogService).to receive(:capture_for_user)
      sub = build_subscription(status: "canceled")
      stub_event(sub, type: "customer.subscription.deleted")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change { AnalyticsEvent.for_event("subscription_canceled").count }.by(1)

      event = AnalyticsEvent.for_event("subscription_canceled").last
      expect(event.user_id).to eq(user.id)
      expect(event.metadata["plan_type"]).to eq("pro")
    end

    it "captures a nil reason when Stripe collected none" do
      user.update!(plan_type: "basic", plan_status: "active")
      sub = build_subscription(status: "canceled", cancellation_details: nil)
      stub_event(sub, type: "customer.subscription.deleted")

      expect(PosthogService).to receive(:capture_for_user).with(
        anything, "subscription_cancelled",
        properties: { plan: "basic", reason: nil },
      )

      post_webhook("{}", header_with_signature)
    end
  end
end
