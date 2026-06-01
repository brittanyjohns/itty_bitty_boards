require "rails_helper"

# Unit-level coverage for plan_type/plan_status transitions on User.
# Companion to:
#   - spec/models/user_spec.rb (basic plan defaults, initial grant)
#   - spec/requests/api/webhooks_plan_type_spec.rb (webhook-driven mutations)
#   - spec/sidekiq/downgrade_soft_trial_job_spec.rb (job-driven downgrade)
RSpec.describe User, type: :model do
  describe "#set_soft_trial_plan" do
    it "promotes a blank plan_type to basic_trial on create" do
      user = User.new(email: "a@example.com", password: "password123", plan_type: nil)
      user.save!
      expect(user.plan_type).to eq("basic_trial")
    end

    it "promotes plan_type='free' to basic_trial when within the trial window" do
      user = User.new(email: "b@example.com", password: "password123", plan_type: "free")
      user.save!
      expect(user.plan_type).to eq("basic_trial")
    end

    it "does NOT overwrite an explicit 'basic' plan on create" do
      user = User.new(email: "c@example.com", password: "password123", plan_type: "basic")
      user.save!
      expect(user.plan_type).to eq("basic")
    end

    it "does NOT overwrite an explicit 'pro' plan on create" do
      user = User.new(email: "d@example.com", password: "password123", plan_type: "pro")
      user.save!
      expect(user.plan_type).to eq("pro")
    end

    # Regression for bug 3 (downgrade-then-save inside trial window).
    it "does NOT re-promote a user who has been deliberately downgraded (paid_plan_type set)" do
      user = FactoryBot.create(:user) # basic_trial inside window
      user.update!(plan_type: "free", paid_plan_type: "basic")
      # Trigger any save — without the paid_plan_type guard, the before_save
      # callback would bounce them back to basic_trial.
      user.touch
      expect(user.reload.plan_type).to eq("free")
    end
  end

  describe "#paid_plan?" do
    # plan_type, plan_status → expected paid_plan?
    cases = [
      # paid types, healthy status
      ["basic", "active", true],
      ["pro", "active", true],
      ["basic_trial", "active", true], # basic_trial.include?("basic") → basic? true
      ["pro", "trialing", true],
      ["basic", nil, true],
      # paid types, unpaid status
      ["pro", "canceled", false],
      ["basic", "paused", false],
      ["pro", "incomplete_expired", false],
      ["basic", "unpaid", false],
      # free types
      ["free", "active", false],
      ["free", "canceled", false],
      [nil, "active", false],
    ]

    cases.each do |plan_type, plan_status, expected|
      it "is #{expected} for plan_type=#{plan_type.inspect} plan_status=#{plan_status.inspect}" do
        user = FactoryBot.build_stubbed(:user, plan_type: plan_type, plan_status: plan_status, role: "user")
        expect(user.paid_plan?).to eq(expected)
      end
    end

    it "is true for admins regardless of plan_type/status" do
      admin = FactoryBot.build_stubbed(:admin_user, plan_type: "free", plan_status: "canceled")
      expect(admin.paid_plan?).to eq(true)
    end
  end

  describe "#pin_default_editable_board!" do
    it "no-ops when editable_board_id is already set" do
      user = FactoryBot.create(:user)
      board = FactoryBot.create(:board, user: user)
      user.update!(editable_board_id: board.id)

      expect { user.pin_default_editable_board! }.not_to change { user.reload.editable_board_id }
    end

    it "no-ops when the user owns zero boards" do
      user = FactoryBot.create(:user)
      expect { user.pin_default_editable_board! }.not_to change { user.reload.editable_board_id }
      expect(user.reload.editable_board_id).to be_nil
    end

    it "pins the most-recently-updated board when no favorite exists" do
      user = FactoryBot.create(:user)
      FactoryBot.create(:board, user: user)
      newest = FactoryBot.create(:board, user: user)

      user.pin_default_editable_board!
      expect(user.reload.editable_board_id).to eq(newest.id)
    end
  end
end
