require "rails_helper"

RSpec.describe ExpirePlanCreditsJob, type: :sidekiq do
  describe "#perform" do
    it "zeros plan credits whose reset_at has passed" do
      user = reset_user_credits!(FactoryBot.create(:user))
      # Simulate an expired grant directly — grant_plan! clamps past period_ends
      # forward, so we can't use it to seed an already-expired state.
      user.update_columns(plan_credits_balance: 100, plan_credits_reset_at: 1.day.ago)

      described_class.new.perform

      user.reload
      expect(user.plan_credits_balance).to eq(0)
      expect(user.credit_transactions.where(kind: "expire").count).to eq(1)
    end

    it "leaves users whose reset_at is in the future alone" do
      user = FactoryBot.create(:user)
      CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)

      expect { described_class.new.perform }.not_to change { user.reload.plan_credits_balance }
    end

    it "leaves top-up credits untouched" do
      user = reset_user_credits!(FactoryBot.create(:user))
      user.update_columns(plan_credits_balance: 50, plan_credits_reset_at: 1.day.ago)
      CreditService.grant_topup!(user, amount: 100, stripe_event_id: "evt_topup_keep")

      described_class.new.perform
      user.reload
      expect(user.plan_credits_balance).to eq(0)
      expect(user.topup_credits_balance).to eq(100)
    end

    it "is a no-op for users with zero plan balance even if reset_at has passed" do
      user = FactoryBot.create(:user)
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: 1.day.ago)

      expect { described_class.new.perform }.not_to change { CreditTransaction.count }
    end

    it "skips users whose plan_credits_reset_at is NULL" do
      user = reset_user_credits!(FactoryBot.create(:user))
      user.update_columns(plan_credits_balance: 50, plan_credits_reset_at: nil)

      expect { described_class.new.perform }.not_to change { user.reload.plan_credits_balance }
    end

    it "is idempotent across runs (second run is a no-op)" do
      user = reset_user_credits!(FactoryBot.create(:user))
      user.update_columns(plan_credits_balance: 30, plan_credits_reset_at: 1.day.ago)
      described_class.new.perform

      expect {
        described_class.new.perform
      }.not_to change { user.reload.credit_transactions.where(kind: "expire").count }
    end

    it "sweeps multiple users in a single run" do
      a = reset_user_credits!(FactoryBot.create(:user))
      b = reset_user_credits!(FactoryBot.create(:user))
      a.update_columns(plan_credits_balance: 10, plan_credits_reset_at: 1.day.ago)
      b.update_columns(plan_credits_balance: 20, plan_credits_reset_at: 1.hour.ago)

      described_class.new.perform

      expect(a.reload.plan_credits_balance).to eq(0)
      expect(b.reload.plan_credits_balance).to eq(0)
    end
  end
end
