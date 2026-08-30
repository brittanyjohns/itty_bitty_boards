# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::StartTrial do
  let(:user) { create(:user, stripe_customer_id: "cus_123") }

  # Stripe::Subscription.create returns an object the service reads `.id`,
  # `.status` and `.trial_end` off.
  def stripe_subscription(id: "sub_123", status: "trialing", trial_end: 14.days.from_now.to_i)
    OpenStruct.new(id: id, status: status, trial_end: trial_end)
  end

  before do
    stub_const("ENV", ENV.to_hash.merge(
      "STRIPE_PRICE_BASIC" => "price_basic",
      "STRIPE_PRICE_PRO" => "price_pro",
    ))
    allow(user).to receive(:ensure_stripe_customer!).and_return("cus_123")
    allow(user).to receive(:send_plan_welcome_email_once!)
  end

  describe "the subscription it creates" do
    it "is a 14-day no-card trial that cancels rather than billing" do
      expect(Stripe::Subscription).to receive(:create).with(
        hash_including(
          customer: "cus_123",
          items: [{ price: "price_basic", quantity: 1 }],
          trial_period_days: 14,
          trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
        ),
      ).and_return(stripe_subscription)

      described_class.call(user, plan_key: "basic")
    end

    it "carries the user, plan and source in metadata so the webhook can attribute it" do
      expect(Stripe::Subscription).to receive(:create).with(
        hash_including(metadata: { user_id: user.id, plan_key: "pro", source: "signup" }),
      ).and_return(stripe_subscription)

      described_class.call(user, plan_key: "pro", source: "signup")
    end

    it "uses the pro price for pro" do
      expect(Stripe::Subscription).to receive(:create).with(
        hash_including(items: [{ price: "price_pro", quantity: 1 }]),
      ).and_return(stripe_subscription)

      described_class.call(user, plan_key: "pro")
    end
  end

  describe "the local plan state it mirrors" do
    let(:trial_end) { 14.days.from_now.to_i }

    before do
      allow(Stripe::Subscription).to receive(:create)
        .and_return(stripe_subscription(status: "trialing", trial_end: trial_end))
    end

    it "puts the user on the trialing plan so the signup response is already correct" do
      described_class.call(user, plan_key: "pro")

      user.reload
      expect(user.plan_type).to eq("pro")
      expect(user.plan_status).to eq("trialing")
      expect(user.paid_plan_type).to eq("pro")
      expect(user.stripe_subscription_id).to eq("sub_123")
    end

    it "records the trial end and that no card is on file" do
      described_class.call(user, plan_key: "basic")

      user.reload
      expect(user.settings["trial_ends_at"]).to eq(Time.at(trial_end).iso8601)
      expect(user.settings["has_payment_method"]).to be(false)
      expect(user.settings["billing_interval"]).to eq("monthly")
    end

    it "applies the plan's limits (the before_save callback, not update_columns)" do
      described_class.call(user, plan_key: "pro")

      user.reload
      # #801 made board_limit resolve from plan_type at READ time, and
      # `settings["board_limit"]` now means only a deliberate admin override —
      # so the trialist's board limit is asserted on the resolved value, and
      # `settings` is expected to stay clean. The communicator limit is still
      # stamped, which is what keeps `save!` (not update_columns) load-bearing:
      # `before_save :setup_limits` is the only thing that writes it.
      expect(user.board_limit).to eq(User::PRO_PLAN_LIMITS["board_limit"])
      expect(user.settings["board_limit"]).to be_nil
      expect(user.settings["paid_communicator_limit"]).to eq(User::PRO_PLAN_LIMITS["paid_communicator_limit"])
    end

    it "reads as an entitled user to the single paid-tier gate" do
      described_class.call(user, plan_key: "basic")

      expect(user.reload.paid_plan?).to be(true)
    end

    it "grants no credits — webhooks are the sole credit-grant authority" do
      expect(CreditService).not_to receive(:grant_plan!)

      described_class.call(user, plan_key: "pro")
    end
  end

  describe "the plan welcome email" do
    before do
      allow(Stripe::Subscription).to receive(:create).and_return(stripe_subscription)
    end

    # The webhook guards its own send on a plan_status TRANSITION into trialing,
    # and mirror_plan_state! has already written that status — so the webhook
    # would never send it.
    it "is sent here, because the webhook can no longer detect the transition" do
      expect(user).to receive(:send_plan_welcome_email_once!).with("basic", source: "signup_trial")

      described_class.call(user, plan_key: "basic")
    end
  end

  describe "analytics" do
    before do
      allow(Stripe::Subscription).to receive(:create).and_return(stripe_subscription)
    end

    it "records trial_started once, with no card required" do
      expect { described_class.call(user, plan_key: "pro") }
        .to change { AnalyticsEvent.for_event("trial_started").count }.by(1)

      event = AnalyticsEvent.for_event("trial_started").last
      expect(event.user_id).to eq(user.id)
      expect(event.metadata["plan_key"]).to eq("pro")
      expect(event.metadata["require_card"]).to be(false)
    end
  end

  describe "the guards" do
    # Each of these must leave the user on Free without calling Stripe at all.
    after { expect(user.reload.plan_type).to eq("free") }

    it "refuses a plan key that isn't Basic or Pro" do
      expect(Stripe::Subscription).not_to receive(:create)

      expect(described_class.call(user, plan_key: "free")).to be_nil
    end

    # The frontend used to send the raw viewType string here.
    it "refuses the legacy viewType strings older clients send" do
      expect(Stripe::Subscription).not_to receive(:create)

      %w[default marketing demo].each do |legacy|
        expect(described_class.call(user, plan_key: legacy)).to be_nil
      end
    end

    it "refuses a blank plan key" do
      expect(Stripe::Subscription).not_to receive(:create)

      expect(described_class.call(user, plan_key: nil)).to be_nil
    end

    # App Store / Play require IAP for subscriptions.
    it "refuses mobile platforms, which must upgrade through RevenueCat" do
      expect(Stripe::Subscription).not_to receive(:create)

      expect(described_class.call(user, plan_key: "pro", platform: "ios")).to be_nil
      expect(described_class.call(user, plan_key: "pro", platform: "android")).to be_nil
    end

    it "refuses when the plan's price env var is unset" do
      stub_const("ENV", ENV.to_hash.merge("STRIPE_PRICE_PRO" => nil))
      expect(Stripe::Subscription).not_to receive(:create)

      expect(described_class.call(user, plan_key: "pro")).to be_nil
    end

    it "refuses a user who already has a subscription" do
      user.update!(stripe_subscription_id: "sub_existing")
      expect(Stripe::Subscription).not_to receive(:create)

      expect(described_class.call(user, plan_key: "pro")).to be_nil
    end
  end

  it "refuses a user who is already entitled" do
    paid = create(:user, stripe_customer_id: "cus_paid", plan_type: "pro", plan_status: "active")
    expect(Stripe::Subscription).not_to receive(:create)

    expect(described_class.call(paid, plan_key: "basic")).to be_nil
    expect(paid.reload.plan_type).to eq("pro")
  end

  it "refuses an admin" do
    admin = create(:admin_user, stripe_customer_id: "cus_admin")
    expect(Stripe::Subscription).not_to receive(:create)

    expect(described_class.call(admin, plan_key: "pro")).to be_nil
  end

  it "returns nil for a nil user rather than raising" do
    expect(described_class.call(nil, plan_key: "pro")).to be_nil
  end

  describe "when Stripe fails" do
    # The account is already created and signed in by the time this runs, so a
    # Stripe outage must leave the user on Free rather than 500 the signup.
    it "swallows the error and leaves the user on Free" do
      allow(Stripe::Subscription).to receive(:create)
        .and_raise(Stripe::APIConnectionError.new("stripe is down"))

      expect { expect(described_class.call(user, plan_key: "pro")).to be_nil }.not_to raise_error

      user.reload
      expect(user.plan_type).to eq("free")
      expect(user.stripe_subscription_id).to be_nil
    end

    it "swallows a failure to resolve the customer" do
      allow(user).to receive(:ensure_stripe_customer!)
        .and_raise(Stripe::InvalidRequestError.new("no such customer", "customer"))

      expect { expect(described_class.call(user, plan_key: "basic")).to be_nil }.not_to raise_error
      expect(user.reload.plan_type).to eq("free")
    end
  end
end
