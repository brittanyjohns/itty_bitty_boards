require "rails_helper"

RSpec.describe DowngradeSoftTrialJob, type: :job do
  subject(:job) { described_class.new }

  def create_soft_trial_user(overrides = {})
    attrs = { plan_type: "basic_trial", stripe_customer_id: "cus_test123", paid_plan_type: nil }.merge(overrides)
    user = FactoryBot.create(:user, **attrs)
    user.update_column(:created_at, 15.days.ago) unless overrides.key?(:created_at)
    user
  end

  describe "#perform" do
    context "when a user is an expired soft-trial Basic user" do
      it "downgrades plan_type to free" do
        user = create_soft_trial_user
        expect { job.perform }.to change { user.reload.plan_type }.from("basic_trial").to("free")
      end

      it "grants the free-tier credit allowance after downgrade" do
        user = create_soft_trial_user
        # Pretend they spent most of their basic_trial allowance.
        user.update_columns(plan_credits_balance: 12, plan_credits_reset_at: 1.day.ago)

        expect { job.perform }.to change { user.reload.plan_credits_balance }.to(5)
        expect(user.plan_credits_reset_at).to be_within(5.seconds).of(30.days.from_now)
        tx = user.credit_transactions.where(kind: "plan_grant").order(created_at: :desc).first
        expect(tx.metadata["source"]).to eq("soft_trial_downgrade")
      end
    end

    context "when a user has no stripe_customer_id (Apple/RevenueCat)" do
      it "does not downgrade the user" do
        user = create_soft_trial_user(stripe_customer_id: nil)
        expect { job.perform }.not_to change { user.reload.plan_type }
      end
    end

    context "when a user has a paid_plan_type set" do
      it "does not downgrade the user" do
        user = create_soft_trial_user(paid_plan_type: "basic")
        expect { job.perform }.not_to change { user.reload.plan_type }
      end
    end

    context "when a user signed up fewer than 14 days ago" do
      it "does not downgrade the user" do
        user = create_soft_trial_user(created_at: 10.days.ago)
        expect { job.perform }.not_to change { user.reload.plan_type }
      end
    end

    context "when a user is already on the free plan" do
      it "does not touch the user" do
        user = create_soft_trial_user
        user.update_column(:plan_type, "free")
        expect { job.perform }.not_to change { user.reload.plan_type }
      end
    end
  end
end
