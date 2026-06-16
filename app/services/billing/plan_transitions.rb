# frozen_string_literal: true

module Billing
  # Shared plan-state transitions used by every billing source (Stripe webhook,
  # RevenueCat webhook). Keeping the downgrade logic in one place means an
  # iOS/App Store cancellation lands a user on free with exactly the same
  # limits, editable-board pin, and credit grant as a Stripe cancellation.
  module PlanTransitions
    module_function

    # Downgrade a user to the free plan. Resets plan_type/limits, snapshots the
    # previous paid plan, pins a default editable board so the user keeps one
    # working edit slot, and grants the free-tier credit allowance immediately
    # (so canceled/paused users aren't stranded at 0 until the daily refresh).
    # Top-up credits are untouched. Idempotent enough to re-run safely.
    def apply_free_plan(user, status = "canceled")
      return if user.nil?

      original_plan_type = user.plan_type
      user.plan_type = User::FREE_PLAN_LIMITS["plan_type"]
      user.paid_plan_type = original_plan_type
      user.plan_status = status
      user.setup_free_limits
      user.stripe_subscription_id = nil
      user.settings.delete("trial_ends_at")
      user.save!
      user.pin_default_editable_board!

      free_amount = CreditService.monthly_credits_for("free")
      CreditService.grant_plan!(
        user,
        amount: free_amount,
        period_end: CreditService.initial_period_end_for("free"),
        metadata: {
          reason: "subscription_#{status}",
          previous_plan_type: original_plan_type,
        },
      )
    end
  end
end
