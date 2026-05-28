require "rails_helper"

# End-to-end safety net for the subscription lifecycle. Walks signup →
# trial → checkout → trialing webhook → invoice (renewal) → upgrade →
# cancel → soft-trial downgrade job. Asserts plan_type/status/credits/
# editable_board_id at each step. When any single handler is edited, this
# spec is the one that catches subtle cross-step regressions.
RSpec.describe "Subscription lifecycle (end-to-end)", type: :request do
  include StripeHelpers

  before do
    ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy"
    ENV["STRIPE_PRICE_BASIC"] = "price_basic_monthly"
    ENV["STRIPE_PRICE_PRO"] = "price_pro_monthly"
    allow(Stripe::PromotionCode).to receive(:list).and_return(OpenStruct.new(data: []))
  end

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def stripe_metadata(hash)
    Class.new do
      def initialize(h) @h = h.transform_keys(&:to_s) end
      def [](k) = @h[k.to_s]
      def presence; @h.presence; end
      def to_h; @h; end
    end.new(hash)
  end

  def build_price(plan_type, monthly_credits, id)
    OpenStruct.new(id: id, metadata: stripe_metadata("plan_type" => plan_type, "monthly_credits" => monthly_credits.to_s))
  end

  def build_subscription(user, status:, price:, current_period_end:, trial_end: nil, id: "sub_#{SecureRandom.hex(3)}")
    OpenStruct.new(
      id: id,
      customer: user.stripe_customer_id,
      status: status,
      current_period_end: current_period_end.to_i,
      trial_end: trial_end&.to_i,
      items: OpenStruct.new(data: [OpenStruct.new(price: price, quantity: 1)]),
    )
  end

  it "walks signup → trial → upgrade → cancel → soft-trial sweep" do
    # ----- Step 1: signup -----
    # New users land in basic_trial with 400 plan credits (User#after_create
    # → CreditService.ensure_initial_grant!) and no Stripe customer yet.
    user = FactoryBot.create(:user, stripe_customer_id: "cus_lifecycle", plan_type: "basic_trial")
    expect(user.plan_type).to eq("basic_trial")
    expect(user.plan_credits_balance).to eq(400)
    expect(user.paid_plan?).to be true # basic_trial.include?("basic") → true

    # ----- Step 2: subscription.created (trialing) — Stripe Checkout completed -----
    basic_price = build_price("basic", 400, "price_basic_monthly")
    trial_end = 14.days.from_now
    trialing_sub = build_subscription(user,
      status: "trialing",
      price: basic_price,
      current_period_end: trial_end + 30.days,
      trial_end: trial_end,
      id: "sub_lifecycle")

    stub_event(trialing_sub, type: "customer.subscription.created", event_id: "evt_lifecycle_trial")
    allow_any_instance_of(User).to receive(:send_welcome_email)
    post_webhook("{}", header_with_signature)

    user.reload
    expect(user.plan_type).to eq("basic")
    expect(user.plan_status).to eq("trialing")
    expect(user.stripe_subscription_id).to eq("sub_lifecycle")
    # Trial credit grant runs alongside subscription.created (status=trialing).
    expect(user.plan_credits_balance).to eq(400)
    expect(user.plan_credits_reset_at).to be_within(60.seconds).of(trial_end)

    # ----- Step 3: invoice.payment_succeeded — trial converts to active -----
    active_sub = build_subscription(user,
      status: "active",
      price: basic_price,
      current_period_end: 30.days.from_now,
      id: "sub_lifecycle")
    invoice = OpenStruct.new(id: "in_first", subscription: active_sub.id)
    allow(Stripe::Subscription).to receive(:retrieve).with("sub_lifecycle").and_return(active_sub)
    stub_event(invoice, type: "invoice.payment_succeeded", event_id: "evt_lifecycle_invoice1")

    post_webhook("{}", header_with_signature)
    user.reload
    expect(user.plan_credits_balance).to eq(400)
    expect(user.plan_credits_reset_at).to be_within(60.seconds).of(Time.at(active_sub.current_period_end))

    # ----- Step 4: subscription.updated — upgrade basic → pro -----
    pro_price = build_price("pro", 1500, "price_pro_monthly")
    pro_sub = build_subscription(user,
      status: "active",
      price: pro_price,
      current_period_end: 30.days.from_now,
      id: "sub_lifecycle")
    stub_event(pro_sub, type: "customer.subscription.updated", event_id: "evt_lifecycle_upgrade")

    post_webhook("{}", header_with_signature)
    user.reload
    expect(user.plan_type).to eq("pro")
    expect(user.plan_status).to eq("active")

    # ----- Step 5: invoice.payment_succeeded on pro tier -----
    allow(Stripe::Subscription).to receive(:retrieve).with("sub_lifecycle").and_return(pro_sub)
    invoice2 = OpenStruct.new(id: "in_pro_renewal", subscription: pro_sub.id)
    stub_event(invoice2, type: "invoice.payment_succeeded", event_id: "evt_lifecycle_invoice2")
    post_webhook("{}", header_with_signature)

    expect(user.reload.plan_credits_balance).to eq(1500)

    # ----- Step 6: subscription.deleted — cancellation -----
    FactoryBot.create(:board, user: user) # ensure pin_default_editable_board! has something to pin
    newest = FactoryBot.create(:board, user: user)

    canceled_sub = build_subscription(user,
      status: "canceled",
      price: pro_price,
      current_period_end: 1.day.ago,
      id: "sub_lifecycle")
    stub_event(canceled_sub, type: "customer.subscription.deleted", event_id: "evt_lifecycle_cancel")
    post_webhook("{}", header_with_signature)

    user.reload
    expect(user.plan_type).to eq("free")
    expect(user.paid_plan_type).to eq("pro")
    expect(user.plan_status).to eq("canceled")
    expect(user.stripe_subscription_id).to be_nil
    expect(user.editable_board_id).to eq(newest.id)
    # Plan credits reset to free tier allowance (not 0).
    expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))
    # paid_plan? respects plan_status="canceled" (bug 6 fix).
    expect(user.paid_plan?).to be false

    # ----- Step 7: soft-trial downgrade job runs after the window — idempotent -----
    # User is already on free + canceled; DowngradeSoftTrialJob should be a
    # no-op for them (filter requires plan_type=basic_trial and paid_plan_type
    # blank).
    user.update_column(:created_at, 20.days.ago)
    expect {
      DowngradeSoftTrialJob.new.perform
    }.not_to change { user.reload.plan_type }
  end

  it "soft-trial user with no Stripe activity gets swept by the downgrade job" do
    user = FactoryBot.create(:user,
      stripe_customer_id: "cus_soft_only",
      plan_type: "basic_trial",
      paid_plan_type: nil)
    user.update_column(:created_at, 20.days.ago)
    expect(user.plan_credits_balance).to eq(400) # initial grant
    user.update_columns(plan_credits_balance: 12, plan_credits_reset_at: 1.day.ago)

    DowngradeSoftTrialJob.new.perform

    user.reload
    expect(user.plan_type).to eq("free")
    expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))
    expect(user.paid_plan?).to be false
  end

  it "an invoice.payment_failed event marks the user past_due without downgrading" do
    user = FactoryBot.create(:user,
      stripe_customer_id: "cus_pastdue",
      plan_type: "basic",
      plan_status: "active",
      stripe_subscription_id: "sub_pastdue")
    sub = build_subscription(user,
      status: "past_due",
      price: build_price("basic", 400, "price_basic_monthly"),
      current_period_end: 30.days.from_now,
      id: "sub_pastdue")
    allow(Stripe::Subscription).to receive(:retrieve).with("sub_pastdue").and_return(sub)
    stub_event(OpenStruct.new(id: "in_failed", subscription: "sub_pastdue"), type: "invoice.payment_failed")

    post_webhook("{}", header_with_signature)

    user.reload
    expect(user.plan_status).to eq("past_due")
    expect(user.plan_type).to eq("basic") # we don't downgrade on a single failed charge
  end
end
