# Monthly credit refresh for users who don't have a Stripe subscription
# driving renewal grants.
#
# Stripe-driven users (subscriptions on file) get their monthly plan credits
# refreshed by the `invoice.payment_succeeded` webhook. Free users — and
# users whose subscription was canceled but who are still active on the
# free tier — have no Stripe billing cycle, so this job is their refresh
# loop. It runs daily; the check is cheap.
#
# Eligibility:
#   - plan_credits_reset_at IS NULL (never granted) OR plan_credits_reset_at <= now
#   - stripe_subscription_id IS NULL OR plan_type is one of the non-paid tiers
#     (covers users who canceled — they still have a stripe_subscription_id
#     until the webhook clears it)
#   - Skip admins
#
# Idempotent on the day's transaction: grant_plan! writes one new row per
# call and expires leftovers. Running twice in the same day double-resets
# the user but doesn't accumulate, so we gate on reset_at.
class RefreshFreeTierCreditsJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  # Tiers without a Stripe subscription driving renewal grants. MySpeak,
  # Basic, Pro, and Partner Pro are paid Stripe subscriptions and get
  # refreshed by `invoice.payment_succeeded` instead.
  NON_PAID_PLAN_TYPES = %w[free basic_trial].freeze

  def perform
    refreshed = 0

    eligible_users.find_each do |user|
      next if user.respond_to?(:admin?) && user.admin?

      plan_type = user.plan_type.presence || "free"
      amount = CreditService.monthly_credits_for(plan_type)
      next if amount <= 0

      CreditService.grant_plan!(
        user,
        amount: amount,
        period_end: CreditService.initial_period_end_for(plan_type),
        metadata: { source: "refresh_free_tier_credits_job", plan_type: plan_type },
      )
      refreshed += 1
    rescue => e
      Rails.logger.error "RefreshFreeTierCreditsJob: failed for user #{user.id} - #{e.class} #{e.message}"
    end

    Rails.logger.info "RefreshFreeTierCreditsJob: refreshed=#{refreshed}"
  end

  private

  def eligible_users
    User
      .where(plan_type: NON_PAID_PLAN_TYPES)
      .where("plan_credits_reset_at IS NULL OR plan_credits_reset_at <= ?", Time.current)
  end
end
