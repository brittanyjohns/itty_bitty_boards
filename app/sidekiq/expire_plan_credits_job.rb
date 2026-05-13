# Backstop for credit expiry.
#
# The primary path for refreshing plan credits is the
# `invoice.payment_succeeded` webhook (see API::WebhooksController), which
# calls `CreditService.grant_plan!` and naturally expires the previous
# period's leftovers. This job catches the edge cases:
#
#   - Subscription churn where the webhook was missed or delayed.
#   - Trial users whose `plan_credits_reset_at` has passed but no payment
#     event will arrive (cancellation just before conversion, etc.).
#
# Run on an hourly cron — idempotent and cheap because
# `CreditService.expire_plan_credits!` is a no-op when the balance is
# already zero.
class ExpirePlanCreditsJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  def perform
    scope = User
      .where("plan_credits_balance > 0")
      .where("plan_credits_reset_at IS NOT NULL AND plan_credits_reset_at <= ?", Time.current)

    expired = 0
    scope.find_each do |user|
      tx = CreditService.expire_plan_credits!(user, reason: "period_ended")
      expired += 1 if tx
    end

    Rails.logger.info "[ExpirePlanCreditsJob] expired plan credits for #{expired} users"
  end
end
