require "rails_helper"

RSpec.describe CreditService, type: :service do
  let(:user) { FactoryBot.create(:user) }

  describe ".cost_for" do
    it "returns the configured weight for a known feature" do
      expect(described_class.cost_for("image_generation")).to eq(5)
      expect(described_class.cost_for(:word_suggestion)).to eq(1)
      expect(described_class.cost_for("menu_create")).to eq(10)
    end

    it "defaults to 1 for unknown features" do
      expect(described_class.cost_for("not_a_feature")).to eq(1)
    end
  end

  describe ".monthly_credits_for" do
    it "returns the configured allowance per plan" do
      expect(described_class.monthly_credits_for("free")).to eq(10)
      expect(described_class.monthly_credits_for("basic")).to eq(400)
      expect(described_class.monthly_credits_for("pro")).to eq(1500)
    end

    it "falls back to free for unknown plan" do
      expect(described_class.monthly_credits_for("nope")).to eq(described_class::PLAN_MONTHLY_CREDITS["free"])
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
      described_class.spend!(user, feature_key: "image_generation") # cost 5
      user.reload
      expect(user.plan_credits_balance).to eq(5)
      expect(user.topup_credits_balance).to eq(50)
      tx = user.credit_transactions.spends.last
      expect(tx.feature_key).to eq("image_generation")
      expect(tx.amount).to eq(-5)
    end

    it "spills into topup when plan is insufficient" do
      described_class.grant_topup!(user, amount: 50, stripe_event_id: "t2")
      described_class.spend!(user, feature_key: "menu_create") # cost 10, plan has 10
      described_class.spend!(user, feature_key: "menu_create") # cost 10, must come from topup
      user.reload
      expect(user.plan_credits_balance).to eq(0)
      expect(user.topup_credits_balance).to eq(40)
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
