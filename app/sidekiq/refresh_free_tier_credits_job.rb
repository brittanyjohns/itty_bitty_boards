# Monthly credit refresh for users who don't have a Stripe subscription
# driving renewal grants.
#
# Stripe-driven paying users get their monthly plan credits refreshed by
# the `invoice.payment_succeeded` webhook. This job covers everyone else:
#
#   - Free-tier users (5 credits/month).
#   - Soft-trial users (`basic_trial`, 400 credits for 14 days).
#   - Paying users without a Stripe subscription — App Store / RevenueCat
#     subscribers, admin/demo accounts on paid tiers, etc. They get their
#     actual plan_type's allowance.
#
# The class name is kept as `RefreshFreeTierCreditsJob` for cron stability
# (see config/schedule.rb / sidekiq cron entry); scope is broader than the
# name suggests.
#
# Eligibility:
#   - plan_type is in REFRESHABLE_PLAN_TYPES
#   - plan_credits_reset_at IS NULL (never granted) OR has passed
#   - stripe_subscription_id is blank (no Stripe-driven renewal incoming)
#   - Skip admins
#
# Idempotent in practice: grant_plan! expires leftovers and sets
# plan_credits_reset_at forward, so the same user won't requalify until
# their next period.
class RefreshFreeTierCreditsJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  # Any plan_type whose allowance we're willing to refresh from this job.
  # Stripe-driven users are excluded by the `stripe_subscription_id` filter
  # below regardless of plan_type.
  REFRESHABLE_PLAN_TYPES = %w[
    free
    basic_trial
    basic
    pro
    partner_pro
    vendor
    premium
  ].freeze

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
        metadata: { source: "refresh_credits_job", plan_type: plan_type },
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
      .where(plan_type: REFRESHABLE_PLAN_TYPES)
      .where("plan_credits_reset_at IS NULL OR plan_credits_reset_at <= ?", Time.current)
      .where(stripe_subscription_id: [nil, ""])
  end
end
