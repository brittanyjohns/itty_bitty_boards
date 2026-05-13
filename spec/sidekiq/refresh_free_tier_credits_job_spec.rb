require "rails_helper"

RSpec.describe RefreshFreeTierCreditsJob, type: :sidekiq do
  describe "#perform" do
    it "refreshes a free user whose plan_credits_reset_at has passed" do
      user = FactoryBot.create(:user, plan_type: "free", created_at: 30.days.ago)
      # Backdate reset_at so the user is eligible
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: 2.days.ago)

      expect {
        described_class.new.perform
      }.to change { user.reload.plan_credits_balance }.from(0).to(10)
      expect(user.plan_credits_reset_at).to be_within(5.seconds).of(30.days.from_now)
    end

    it "refreshes a basic_trial user whose reset_at has passed" do
      user = FactoryBot.create(:user) # defaults to basic_trial
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: 1.minute.ago)

      described_class.new.perform
      expect(user.reload.plan_credits_balance).to eq(400)
    end

    it "leaves users whose reset_at is in the future alone" do
      user = FactoryBot.create(:user, plan_type: "free", created_at: 30.days.ago)
      user.update_columns(plan_credits_balance: 5, plan_credits_reset_at: 5.days.from_now)

      expect { described_class.new.perform }.not_to change { user.reload.plan_credits_balance }
    end

    it "leaves paid users alone (their refresh comes from invoice.payment_succeeded)" do
      user = FactoryBot.create(:user, plan_type: "pro")
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: 2.days.ago)

      expect { described_class.new.perform }.not_to change { user.reload.plan_credits_balance }
    end

    it "leaves myspeak users alone (paid Stripe subscription)" do
      user = FactoryBot.create(:user, plan_type: "myspeak")
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: 2.days.ago)

      expect { described_class.new.perform }.not_to change { user.reload.plan_credits_balance }
    end

    it "skips admins" do
      admin = FactoryBot.create(:admin_user)
      admin.update_columns(plan_type: "free", plan_credits_balance: 0, plan_credits_reset_at: 2.days.ago)

      expect { described_class.new.perform }.not_to change { admin.reload.plan_credits_balance }
    end

    it "expires leftover credits before granting (no rollover for plan credits)" do
      user = FactoryBot.create(:user, plan_type: "free", created_at: 30.days.ago)
      user.update_columns(plan_credits_balance: 7, plan_credits_reset_at: 2.days.ago)

      described_class.new.perform
      user.reload
      expect(user.plan_credits_balance).to eq(10)
      expect(user.credit_transactions.where(kind: "expire", source: "plan").count).to be >= 1
    end

    it "leaves top-up credits untouched" do
      user = FactoryBot.create(:user, plan_type: "free", created_at: 30.days.ago)
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: 2.days.ago, topup_credits_balance: 50)

      described_class.new.perform
      expect(user.reload.topup_credits_balance).to eq(50)
    end
  end
end
