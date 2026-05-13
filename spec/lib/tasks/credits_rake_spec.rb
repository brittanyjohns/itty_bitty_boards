require "rails_helper"
require "rake"

RSpec.describe "credits rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task[task_name] }

  after { task.reenable }

  describe "credits:backfill" do
    let(:task_name) { "credits:backfill" }

    it "uses 30.days.from_now when plan_expires_at is stale" do
      user = reset_user_credits!(FactoryBot.create(:user, plan_type: "pro"))
      user.update_columns(plan_expires_at: 2.months.ago)

      task.invoke

      grant = user.credit_transactions.find_by(kind: "plan_grant")
      expect(grant).to be_present
      expect(grant.expires_at).to be > Time.current
      expect(grant.expires_at).to be_within(1.minute).of(30.days.from_now)
    end

    it "uses plan_expires_at when it is in the future" do
      future = 45.days.from_now
      user = reset_user_credits!(FactoryBot.create(:user, plan_type: "pro"))
      user.update_columns(plan_expires_at: future)

      task.invoke

      grant = user.credit_transactions.find_by(kind: "plan_grant")
      expect(grant.expires_at).to be_within(1.second).of(future)
    end

    it "uses 30.days.from_now when plan_expires_at is nil" do
      user = reset_user_credits!(FactoryBot.create(:user, plan_type: "pro"))
      user.update_columns(plan_expires_at: nil)

      task.invoke

      grant = user.credit_transactions.find_by(kind: "plan_grant")
      expect(grant.expires_at).to be_within(1.minute).of(30.days.from_now)
    end

    it "skips users who already have a plan_grant row" do
      user = FactoryBot.create(:user, plan_type: "pro")
      # ensure_initial_grant! already created a plan_grant on after_create
      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(1)
      grant_before = user.credit_transactions.find_by(kind: "plan_grant")

      task.invoke

      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(1)
      expect(user.credit_transactions.find_by(kind: "plan_grant").id).to eq(grant_before.id)
    end
  end

  describe "credits:regrant_stale_backfill" do
    let(:task_name) { "credits:regrant_stale_backfill" }

    def seed_stale_backfill_victim!(plan_type: "pro")
      user = reset_user_credits!(FactoryBot.create(:user, plan_type: plan_type))
      CreditTransaction.create!(
        user: user,
        amount: 1500,
        kind: "plan_grant",
        source: "plan",
        expires_at: 2.months.ago,
        metadata: { reason: "phase1_backfill", plan_type: plan_type },
      )
      CreditTransaction.create!(
        user: user,
        amount: -1500,
        kind: "expire",
        source: "plan",
        metadata: { reason: "period_ended" },
      )
      user.update_columns(plan_credits_balance: 0, plan_credits_reset_at: 2.months.ago)
      user
    end

    it "re-grants users zeroed out by the stale-backfill bug" do
      user = seed_stale_backfill_victim!(plan_type: "pro")

      task.invoke

      user.reload
      expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("pro"))
      latest_grant = user.credit_transactions.where(kind: "plan_grant").order(:created_at).last
      expect(latest_grant.expires_at).to be > Time.current
      expect(latest_grant.metadata["reason"]).to eq("manual_regrant_stale_plan_expires_at")
    end

    it "does not re-grant users with a healthy non-zero plan balance" do
      user = FactoryBot.create(:user, plan_type: "pro")
      # User has a fresh plan_grant from after_create and a positive balance — skip them.
      grants_before = user.credit_transactions.where(kind: "plan_grant").count

      task.invoke

      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(grants_before)
    end

    it "does not re-grant users zeroed out for unrelated reasons (no period_ended expire row)" do
      user = reset_user_credits!(FactoryBot.create(:user, plan_type: "free"))
      CreditTransaction.create!(
        user: user,
        amount: 25,
        kind: "plan_grant",
        source: "plan",
        expires_at: 30.days.from_now,
        metadata: { reason: "phase1_backfill", plan_type: "free" },
      )
      CreditTransaction.create!(
        user: user,
        amount: -25,
        kind: "spend",
        source: "plan",
        metadata: { reason: "ai_feature_x" },
      )
      user.update_columns(plan_credits_balance: 0)

      task.invoke

      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(1)
    end
  end
end
