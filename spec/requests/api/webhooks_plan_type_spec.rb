require "rails_helper"

# Covers plan_type / plan_status mutation paths on the Stripe webhook,
# distinct from spec/requests/api/webhooks_plan_credits_spec.rb which
# focuses on credit ledger changes.
RSpec.describe "POST /api/webhooks (plan_type)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_plan_type_user",
      plan_type: "basic",
      plan_status: "active")
  end

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  # Stripe::StripeObject-style metadata that responds to [] with string keys.
  def build_metadata(hash)
    Class.new do
      def initialize(h) @h = h.transform_keys(&:to_s) end
      def [](k) = @h[k.to_s]
      def presence; @h.presence; end
      def to_h; @h; end
    end.new(hash)
  end

  def build_price(plan_type: "pro", monthly_credits: 1500, id: "price_pro")
    meta_hash = {}
    meta_hash["plan_type"] = plan_type if plan_type
    meta_hash["monthly_credits"] = monthly_credits.to_s if monthly_credits
    OpenStruct.new(id: id, metadata: build_metadata(meta_hash))
  end

  def build_subscription(status: "active", price: build_price, current_period_end: 30.days.from_now, trial_end: nil, customer: user.stripe_customer_id)
    OpenStruct.new(
      id: "sub_#{SecureRandom.hex(3)}",
      customer: customer,
      status: status,
      current_period_end: current_period_end.to_i,
      trial_end: trial_end&.to_i,
      items: OpenStruct.new(data: [OpenStruct.new(price: price, quantity: 1)]),
    )
  end

  describe "customer.subscription.updated (Price metadata present)" do
    it "upgrades plan_type from basic to pro" do
      sub = build_subscription(price: build_price(plan_type: "pro", monthly_credits: 1500))
      stub_event(sub, type: "customer.subscription.updated")

      post_webhook("{}", header_with_signature)

      user.reload
      expect(user.plan_type).to eq("pro")
      expect(user.plan_status).to eq("active")
    end

    it "downgrades plan_type from pro to basic" do
      user.update!(plan_type: "pro")
      sub = build_subscription(price: build_price(plan_type: "basic", monthly_credits: 400, id: "price_basic"))
      stub_event(sub, type: "customer.subscription.updated")

      post_webhook("{}", header_with_signature)

      expect(user.reload.plan_type).to eq("basic")
    end

    it "captures trialing status from Stripe" do
      sub = build_subscription(status: "trialing", trial_end: 14.days.from_now)
      stub_event(sub, type: "customer.subscription.updated")

      post_webhook("{}", header_with_signature)

      expect(user.reload.plan_status).to eq("trialing")
    end
  end

  describe "customer.subscription.updated (Price metadata MISSING)" do
    it "does NOT overwrite plan_type to 'free' when the Price has no plan_type metadata" do
      # Regression: handle_subscription_upsert used to fall back to "free"
      # when meta["plan_type"] was blank, silently downgrading paid users.
      empty_price = OpenStruct.new(id: "price_no_meta", metadata: build_metadata({}))
      sub = build_subscription(price: empty_price)
      stub_event(sub, type: "customer.subscription.updated")

      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change { user.reload.plan_type }
      expect(user.plan_type).to eq("basic")
    end
  end

  describe "customer.subscription.created (active)" do
    it "sets plan_type and plan_status, fires welcome email" do
      user.update!(plan_type: "free", plan_status: nil, settings: {})
      sub = build_subscription(price: build_price(plan_type: "pro"))
      stub_event(sub, type: "customer.subscription.created")

      expect_any_instance_of(User).to receive(:send_welcome_email).at_least(:once)

      post_webhook("{}", header_with_signature)

      user.reload
      expect(user.plan_type).to eq("pro")
      expect(user.plan_status).to eq("active")
    end

    it "skips admin users" do
      user.update!(role: "admin")
      sub = build_subscription(price: build_price(plan_type: "pro"))
      stub_event(sub, type: "customer.subscription.created")

      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change { user.reload.plan_type }
    end
  end

  describe "customer.subscription.deleted" do
    it "preserves paid_plan_type and sets plan_status='canceled'" do
      user.update!(plan_type: "pro", paid_plan_type: nil)
      sub = build_subscription
      stub_event(sub, type: "customer.subscription.deleted")

      post_webhook("{}", header_with_signature)

      user.reload
      expect(user.plan_type).to eq("free")
      expect(user.paid_plan_type).to eq("pro")
      expect(user.plan_status).to eq("canceled")
      expect(user.stripe_subscription_id).to be_nil
    end
  end

  describe "customer.subscription.paused" do
    it "flips plan_status to 'paused' and downgrades plan_type" do
      user.update!(plan_type: "pro")
      sub = build_subscription(status: "paused")
      stub_event(sub, type: "customer.subscription.paused")

      post_webhook("{}", header_with_signature)

      user.reload
      expect(user.plan_type).to eq("free")
      expect(user.plan_status).to eq("paused")
      expect(user.paid_plan_type).to eq("pro")
    end

    it "pins a default editable board on the paused user" do
      user.update!(plan_type: "pro")
      create(:board, user: user)
      newest = create(:board, user: user)

      sub = build_subscription(status: "paused")
      stub_event(sub, type: "customer.subscription.paused")

      post_webhook("{}", header_with_signature)

      expect(user.reload.editable_board_id).to eq(newest.id)
    end
  end

  describe "checkout.session.completed (non-topup subscription link)" do
    def build_session(metadata: { "user_id" => user.id.to_s }, customer: "cus_plan_type_user", subscription: "sub_new_123", email: user.email)
      OpenStruct.new(
        id: "cs_test_#{SecureRandom.hex(3)}",
        customer: customer,
        subscription: subscription,
        customer_details: OpenStruct.new(email: email),
        metadata: metadata,
      )
    end

    it "links stripe_customer_id and stripe_subscription_id to the user from metadata.user_id" do
      user.update!(stripe_customer_id: nil, stripe_subscription_id: nil)
      session = build_session
      stub_event(session, type: "checkout.session.completed")

      post_webhook("{}", header_with_signature)

      user.reload
      expect(user.stripe_customer_id).to eq("cus_plan_type_user")
      expect(user.stripe_subscription_id).to eq("sub_new_123")
    end

    it "falls back to email lookup when metadata.user_id is missing" do
      user.update!(stripe_customer_id: nil, stripe_subscription_id: nil)
      session = build_session(metadata: {})
      stub_event(session, type: "checkout.session.completed")

      post_webhook("{}", header_with_signature)

      expect(user.reload.stripe_subscription_id).to eq("sub_new_123")
    end
  end

  describe "invoice.payment_failed" do
    it "flips plan_status to 'past_due'" do
      sub = build_subscription
      invoice = OpenStruct.new(id: "in_fail_1", subscription: sub.id)
      allow(Stripe::Subscription).to receive(:retrieve).with(sub.id).and_return(sub)
      stub_event(invoice, type: "invoice.payment_failed")

      post_webhook("{}", header_with_signature)

      expect(user.reload.plan_status).to eq("past_due")
    end
  end

  describe "invoice.payment_succeeded (Stripe API shape compatibility)" do
    # The new Stripe API moves invoice.subscription to
    # invoice.parent.subscription_details.subscription. Read both shapes.
    let(:sub) { build_subscription }

    before do
      allow(Stripe::Subscription).to receive(:retrieve).with(sub.id).and_return(sub)
    end

    it "reads invoice.subscription (old shape)" do
      invoice = OpenStruct.new(id: "in_old", subscription: sub.id)
      stub_event(invoice, type: "invoice.payment_succeeded", event_id: "evt_old")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change { user.reload.plan_credits_balance }.to(1500)
    end

    it "reads invoice.parent.subscription_details.subscription (new shape)" do
      invoice = OpenStruct.new(
        id: "in_new",
        subscription: nil,
        parent: OpenStruct.new(
          subscription_details: OpenStruct.new(subscription: sub.id),
        ),
      )
      stub_event(invoice, type: "invoice.payment_succeeded", event_id: "evt_new")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change { user.reload.plan_credits_balance }.to(1500)
    end
  end
end
