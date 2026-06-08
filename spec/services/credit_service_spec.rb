require "rails_helper"

RSpec.describe CreditService, type: :service do
  let(:user) { FactoryBot.create(:user) }

  # New users land on `free` and get an after_create plan_grant (5).
  # These specs test CreditService in isolation, so wipe the auto-grant first.
  before { reset_user_credits!(user) }

  describe ".cost_for" do
    it "returns the configured weight for a known feature" do
      expect(described_class.cost_for("image_generation")).to eq(3)
      expect(described_class.cost_for(:word_suggestion)).to eq(1)
      expect(described_class.cost_for("menu_create")).to eq(5)
    end

    it "defaults to 1 for unknown features" do
      expect(described_class.cost_for("not_a_feature")).to eq(1)
    end
  end

  describe ".monthly_credits_for" do
    it "returns the configured allowance per plan" do
      expect(described_class.monthly_credits_for("free")).to eq(5)
      expect(described_class.monthly_credits_for("basic")).to eq(400)
      expect(described_class.monthly_credits_for("basic_trial")).to eq(400)
      expect(described_class.monthly_credits_for("pro")).to eq(1500)
    end

    it "falls back to free for unknown plan" do
      expect(described_class.monthly_credits_for("nope")).to eq(described_class::PLAN_MONTHLY_CREDITS["free"])
    end
  end

  describe ".initial_period_end_for" do
    it "is 14 days for basic_trial (matches the soft-trial window)" do
      from = Time.utc(2026, 5, 1)
      expect(described_class.initial_period_end_for("basic_trial", from: from)).to eq(from + 14.days)
    end

    it "is 30 days by default for other plans" do
      from = Time.utc(2026, 5, 1)
      expect(described_class.initial_period_end_for("free", from: from)).to eq(from + 30.days)
      expect(described_class.initial_period_end_for("basic", from: from)).to eq(from + 30.days)
    end
  end

  describe ".ensure_initial_grant!" do
    it "grants the tier's monthly allowance with the right expiry on first call" do
      user.update_column(:plan_type, "basic_trial")
      # Clear any after_create grant so we can test the method in isolation
      user.credit_transactions.destroy_all
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: nil)

      tx = described_class.ensure_initial_grant!(user)
      expect(tx).to be_present
      expect(tx.kind).to eq("plan_grant")
      expect(tx.amount).to eq(400)
      expect(tx.expires_at).to be_within(2.seconds).of(14.days.from_now)
      expect(user.reload.plan_credits_balance).to eq(400)
    end

    it "is idempotent: a second call returns the existing grant without adding credits" do
      user.update_column(:plan_type, "free")
      first = described_class.ensure_initial_grant!(user)
      expect {
        second = described_class.ensure_initial_grant!(user)
        expect(second.id).to eq(first.id)
      }.not_to change { user.reload.credit_transactions.where(kind: "plan_grant").count }
    end

    it "is a no-op for admins" do
      admin = FactoryBot.create(:admin_user)
      admin.credit_transactions.destroy_all
      expect(described_class.ensure_initial_grant!(admin)).to be_nil
      expect(admin.reload.credit_transactions.where(kind: "plan_grant")).to be_empty
    end
  end

  describe ".grant_plan!" do
    it "sets plan_credits_balance and writes a plan_grant row" do
      period_end = 30.days.from_now
      described_class.grant_plan!(user, amount: 100, period_end: period_end)
      user.reload
      expect(user.plan_credits_balance).to eq(100)
      expect(user.plan_credits_reset_at).to be_within(2.seconds).of(period_end)
      tx = user.credit_transactions.last
      expect(tx.kind).to eq("plan_grant")
      expect(tx.amount).to eq(100)
      expect(tx.source).to eq("plan")
      expect(tx.expires_at).to be_within(2.seconds).of(period_end)
    end

    it "is idempotent on stripe_event_id" do
      described_class.grant_plan!(user, amount: 100, period_end: 30.days.from_now, stripe_event_id: "evt_1")
      described_class.grant_plan!(user, amount: 100, period_end: 30.days.from_now, stripe_event_id: "evt_1")
      user.reload
      expect(user.plan_credits_balance).to eq(100)
      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(1)
    end

    it "expires leftover plan credits before granting" do
      described_class.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      described_class.grant_plan!(user, amount: 200, period_end: 30.days.from_now)
      user.reload
      expect(user.plan_credits_balance).to eq(200)
      expect(user.credit_transactions.where(kind: "expire", source: "plan").count).to eq(1)
    end

    context "period_end clamp (prevents same-day-expire bug, issue #110)" do
      it "clamps a past period_end forward to MIN_GRANT_WINDOW" do
        allow(Rails.logger).to receive(:warn)
        described_class.grant_plan!(user, amount: 100, period_end: 1.day.ago)
        user.reload
        expect(user.plan_credits_reset_at).to be_within(5.seconds)
          .of(Time.current + described_class::MIN_GRANT_WINDOW)
        expect(user.credit_transactions.where(kind: "plan_grant").last.expires_at)
          .to be_within(5.seconds).of(Time.current + described_class::MIN_GRANT_WINDOW)
      end

      it "clamps a Time.current period_end forward" do
        allow(Rails.logger).to receive(:warn)
        described_class.grant_plan!(user, amount: 100, period_end: Time.current)
        user.reload
        expect(user.plan_credits_reset_at).to be_within(5.seconds)
          .of(Time.current + described_class::MIN_GRANT_WINDOW)
      end

      it "clamps a nil period_end forward" do
        allow(Rails.logger).to receive(:warn)
        described_class.grant_plan!(user, amount: 100, period_end: nil)
        user.reload
        expect(user.plan_credits_reset_at).to be_within(5.seconds)
          .of(Time.current + described_class::MIN_GRANT_WINDOW)
      end

      it "leaves a future period_end within the window untouched" do
        future = 20.days.from_now
        described_class.grant_plan!(user, amount: 100, period_end: future)
        user.reload
        expect(user.plan_credits_reset_at).to be_within(2.seconds).of(future)
      end

      it "caps a period_end beyond MAX_GRANT_WINDOW (yearly billing) to the window" do
        described_class.grant_plan!(user, amount: 400, period_end: 365.days.from_now)
        user.reload
        # A yearly subscriber's reset is pulled back to ~1 month so credits
        # refresh monthly instead of once a year.
        expect(user.plan_credits_reset_at).to be_within(5.seconds)
          .of(Time.current + described_class::MAX_GRANT_WINDOW)
      end

      it "leaves a monthly period_end (≤ MAX_GRANT_WINDOW) uncapped" do
        monthly = 30.days.from_now
        described_class.grant_plan!(user, amount: 400, period_end: monthly)
        user.reload
        expect(user.plan_credits_reset_at).to be_within(2.seconds).of(monthly)
      end

      it "logs a warning when clamping" do
        expect(Rails.logger).to receive(:warn).with(/too soon; clamping/)
        described_class.grant_plan!(user, amount: 100, period_end: 1.hour.ago)
      end
    end
  end

  describe ".grant_topup!" do
    it "adds to topup balance and writes a topup_purchase row" do
      described_class.grant_topup!(user, amount: 500, stripe_event_id: "evt_topup_1")
      user.reload
      expect(user.topup_credits_balance).to eq(500)
      tx = user.credit_transactions.last
      expect(tx.kind).to eq("topup_purchase")
      expect(tx.source).to eq("topup")
      expect(tx.amount).to eq(500)
    end

    it "stacks additive purchases" do
      described_class.grant_topup!(user, amount: 100, stripe_event_id: "evt_a")
      described_class.grant_topup!(user, amount: 250, stripe_event_id: "evt_b")
      user.reload
      expect(user.topup_credits_balance).to eq(350)
    end

    it "is idempotent on stripe_event_id" do
      described_class.grant_topup!(user, amount: 100, stripe_event_id: "evt_dup")
      described_class.grant_topup!(user, amount: 100, stripe_event_id: "evt_dup")
      user.reload
      expect(user.topup_credits_balance).to eq(100)
    end
  end

  describe ".spend!" do
    before do
      described_class.grant_plan!(user, amount: 10, period_end: 30.days.from_now)
    end

    it "drains plan credits first" do
      described_class.grant_topup!(user, amount: 50, stripe_event_id: "t1")
      described_class.spend!(user, feature_key: "image_generation") # cost 3
      user.reload
      expect(user.plan_credits_balance).to eq(7)
      expect(user.topup_credits_balance).to eq(50)
      tx = user.credit_transactions.spends.last
      expect(tx.feature_key).to eq("image_generation")
      expect(tx.amount).to eq(-3)
    end

    it "spills into topup when plan is insufficient" do
      described_class.grant_topup!(user, amount: 50, stripe_event_id: "t2")
      # plan starts at 10; three menu_create spends (cost 5 each) total 15,
      # so the third must draw from topup.
      described_class.spend!(user, feature_key: "menu_create") # cost 5, plan 10 -> 5
      described_class.spend!(user, feature_key: "menu_create") # cost 5, plan 5 -> 0
      described_class.spend!(user, feature_key: "menu_create") # cost 5, from topup 50 -> 45
      user.reload
      expect(user.plan_credits_balance).to eq(0)
      expect(user.topup_credits_balance).to eq(45)
    end

    it "raises InsufficientCredits when total balance < cost" do
      # plan=10, topup=0, try to spend 11
      expect {
        described_class.spend!(user, feature_key: "image_generation", amount: 11)
      }.to raise_error(CreditService::InsufficientCredits) do |e|
        expect(e.needed).to eq(11)
        expect(e.balance).to eq(10)
        expect(e.feature_key).to eq("image_generation")
      end
      user.reload
      expect(user.plan_credits_balance).to eq(10) # untouched
    end

    it "accepts explicit amount override" do
      described_class.spend!(user, feature_key: "image_generation", amount: 3)
      user.reload
      expect(user.plan_credits_balance).to eq(7)
    end

    it "rejects non-positive amounts" do
      expect {
        described_class.spend!(user, feature_key: "image_generation", amount: 0)
      }.to raise_error(ArgumentError)
    end
  end

  describe ".expire_plan_credits!" do
    it "zeros the plan balance and writes an expire row" do
      described_class.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      described_class.expire_plan_credits!(user)
      user.reload
      expect(user.plan_credits_balance).to eq(0)
      expect(user.credit_transactions.where(kind: "expire").count).to eq(1)
    end

    it "is a no-op when balance is already zero" do
      result = described_class.expire_plan_credits!(user)
      expect(result).to be_nil
      expect(user.credit_transactions.where(kind: "expire").count).to eq(0)
    end

    it "does not touch topup balance" do
      described_class.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      described_class.grant_topup!(user, amount: 50, stripe_event_id: "t3")
      described_class.expire_plan_credits!(user)
      user.reload
      expect(user.topup_credits_balance).to eq(50)
    end
  end

  describe ".refund!" do
    it "returns credits to the named source" do
      described_class.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      described_class.spend!(user, feature_key: "image_generation", amount: 5)
      described_class.refund!(user, amount: 5, feature_key: "image_generation", source: "plan")
      user.reload
      expect(user.plan_credits_balance).to eq(100)
    end
  end

  describe ".balance" do
    it "returns plan, topup, total, reset_at" do
      described_class.grant_plan!(user, amount: 10, period_end: 30.days.from_now)
      described_class.grant_topup!(user, amount: 5, stripe_event_id: "evt_b")
      user.reload
      b = described_class.balance(user)
      expect(b[:plan]).to eq(10)
      expect(b[:topup]).to eq(5)
      expect(b[:total]).to eq(15)
      expect(b[:reset_at]).to be_present
    end
  end

  describe ".shadow_spend" do
    it "returns true and decrements when there are enough credits" do
      described_class.grant_plan!(user, amount: 10, period_end: 30.days.from_now)
      expect(described_class.shadow_spend(user, feature_key: "word_suggestion")).to be true
      user.reload
      expect(user.plan_credits_balance).to eq(9)
    end

    it "returns false but does not raise when balance is insufficient" do
      expect(described_class.shadow_spend(user, feature_key: "image_generation")).to be false
    end
  end
end
