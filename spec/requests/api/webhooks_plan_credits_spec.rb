require "rails_helper"

# Phase 4: plan-credit grants flow from Stripe webhooks.
# - invoice.payment_succeeded => grant plan credits for the new billing period
# - customer.subscription.created (status=trialing) => grant trial credits
# - customer.subscription.deleted / .paused => expire plan credits
RSpec.describe "POST /api/webhooks (plan credits)", type: :request do
  include StripeHelpers

  let!(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_plan_user") }

  before do
    ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy"
    # New users get an after_create plan_grant; clear it so these webhook
    # specs can assert exact "from 0 to N" changes.
    reset_user_credits!(user)
  end

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def build_price(plan_type: "basic", monthly_credits: 400, id: "price_basic")
    fake_metadata = Class.new do
      def initialize(h) @h = h.transform_keys(&:to_s) end
      def [](k) = @h[k.to_s]
      def presence; @h.presence; end
    end.new("plan_type" => plan_type, "monthly_credits" => monthly_credits.to_s)
    OpenStruct.new(id: id, metadata: fake_metadata)
  end

  def build_subscription(status: "active", price: build_price, current_period_end: 30.days.from_now, trial_end: nil)
    OpenStruct.new(
      id: "sub_test_#{SecureRandom.hex(3)}",
      customer: user.stripe_customer_id,
      status: status,
      current_period_end: current_period_end.to_i,
      trial_end: trial_end&.to_i,
      items: OpenStruct.new(data: [OpenStruct.new(price: price, quantity: 1)]),
    )
  end

  describe "invoice.payment_succeeded" do
    let(:subscription) { build_subscription }
    let(:invoice) { OpenStruct.new(id: "in_test_1", subscription: subscription.id) }

    before do
      allow(Stripe::Subscription).to receive(:retrieve).with(subscription.id).and_return(subscription)
    end

    it "grants the monthly_credits from Price metadata, idempotent on event id" do
      event = stub_event(invoice, type: "invoice.payment_succeeded")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change { user.reload.plan_credits_balance }.from(0).to(400)
      expect(response).to have_http_status(:ok)

      tx = user.credit_transactions.where(stripe_event_id: event.id).first
      expect(tx).to be_present
      expect(tx.kind).to eq("plan_grant")
      expect(tx.amount).to eq(400)
      expect(tx.expires_at).to be_within(60.seconds).of(Time.at(subscription.current_period_end))

      # Replay same event — no double-credit
      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change { user.reload.plan_credits_balance }
    end

    it "renewal: a fresh invoice replaces leftover plan credits from the previous period" do
      # Existing balance from a prior period
      CreditService.grant_plan!(user, amount: 50, period_end: 1.day.ago)
      stub_event(invoice, type: "invoice.payment_succeeded", event_id: "evt_renewal")
      expect {
        post_webhook("{}", header_with_signature)
      }.to change { user.reload.plan_credits_balance }.to(400)
      # Leftover got expired and re-granted, not stacked
      expect(user.credit_transactions.where(kind: "expire").count).to eq(1)
    end

    it "falls back to CreditService.monthly_credits_for(plan_type) when metadata is absent" do
      price_without_credits = OpenStruct.new(id: "price_x", metadata: OpenStruct.new("[]" => ->(_) { nil }))
      # Use a real hash-like metadata that returns nil for both keys
      empty_meta = Class.new { def [](_) = nil }.new
      price = OpenStruct.new(id: "price_x", metadata: empty_meta)
      sub_no_meta = build_subscription(price: price)
      sub_no_meta.define_singleton_method(:id) { "sub_no_meta" }
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_no_meta").and_return(sub_no_meta)

      user.update!(plan_type: "pro")
      stub_event(OpenStruct.new(id: "in_2", subscription: "sub_no_meta"), type: "invoice.payment_succeeded")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change { user.reload.plan_credits_balance }.to(CreditService.monthly_credits_for("pro"))
    end

    it "skips admins" do
      user.update!(role: "admin")
      stub_event(invoice, type: "invoice.payment_succeeded", event_id: "evt_admin")
      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change { user.reload.plan_credits_balance }
    end
  end

  describe "customer.subscription.created (trialing)" do
    it "grants credits with expiry = trial_end" do
      trial_end = 14.days.from_now
      subscription = build_subscription(status: "trialing", trial_end: trial_end)
      stub_event(subscription, type: "customer.subscription.created", event_id: "evt_trial_1")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change { user.reload.plan_credits_balance }.from(0).to(400)

      tx = user.credit_transactions.where(stripe_event_id: "evt_trial_1").first
      expect(tx.expires_at).to be_within(60.seconds).of(trial_end)
    end

    it "does NOT grant when status is active (invoice.payment_succeeded covers paid subs)" do
      subscription = build_subscription(status: "active")
      stub_event(subscription, type: "customer.subscription.created")

      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change { user.reload.plan_credits_balance }
    end
  end

  describe "customer.subscription.deleted" do
    it "expires the paid plan credits and grants the free-tier allowance, keeping top-ups" do
      CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      CreditService.grant_topup!(user, amount: 50, stripe_event_id: "evt_topup_seed")

      subscription = build_subscription
      stub_event(subscription, type: "customer.subscription.deleted")

      post_webhook("{}", header_with_signature)
      user.reload
      # Canceled users land on free with 5 credits, not 0 — so they aren't
      # stranded until the next daily refresh job.
      expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))
      expect(user.topup_credits_balance).to eq(50)
      # Ledger has an `expire` row for the old balance and a new `plan_grant`
      # row for the free allowance.
      expect(user.credit_transactions.where(kind: "expire", source: "plan").count).to be >= 1
      expect(user.credit_transactions.where(kind: "plan_grant").last.amount)
        .to eq(CreditService.monthly_credits_for("free"))
      # plan_credits_reset_at pushed out so ExpirePlanCreditsJob won't sweep
      # immediately.
      expect(user.plan_credits_reset_at).to be > Time.current + CreditService::MIN_GRANT_WINDOW
    end

    it "pins a default editable board so the downgraded user keeps one edit slot" do
      create(:board, user: user)
      newest = create(:board, user: user)

      subscription = build_subscription
      stub_event(subscription, type: "customer.subscription.deleted")

      post_webhook("{}", header_with_signature)

      expect(user.reload.editable_board_id).to eq(newest.id)
    end
  end

  describe "customer.subscription.paused" do
    it "grants the free-tier allowance and marks status=paused" do
      CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      subscription = build_subscription(status: "paused")
      stub_event(subscription, type: "customer.subscription.paused")

      post_webhook("{}", header_with_signature)
      user.reload
      expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))
      expect(user.plan_status).to eq("paused")
    end
  end
end
