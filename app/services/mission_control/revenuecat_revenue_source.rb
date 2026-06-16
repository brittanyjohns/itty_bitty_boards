module MissionControl
  class RevenuecatRevenueSource
    # Estimated monthly prices (cents) for App Store plans. App Store prices
    # generally match Stripe; these are fallbacks when the Stripe Price lookup
    # isn't worth the API call. Override via ENV if they drift.
    ESTIMATED_MONTHLY_PRICES_CENTS = {
      "basic"  => ENV.fetch("RC_ESTIMATED_BASIC_MONTHLY_CENTS", "499").to_i,
      "pro"    => ENV.fetch("RC_ESTIMATED_PRO_MONTHLY_CENTS", "999").to_i,
    }.freeze

    ESTIMATED_YEARLY_PRICES_CENTS = {
      "basic"  => ENV.fetch("RC_ESTIMATED_BASIC_YEARLY_CENTS", "4999").to_i,
      "pro"    => ENV.fetch("RC_ESTIMATED_PRO_YEARLY_CENTS", "9999").to_i,
    }.freeze

    ACTIVE_STATUSES = %w[active trialing].freeze

    def self.call = new.call

    def call
      users = revenuecat_paid_users
      plan_counts = Hash.new(0)
      total_monthly_cents = 0

      users.find_each do |user|
        plan = user.plan_type
        plan_counts[plan] += 1
        total_monthly_cents += estimated_monthly_cents(plan, user.settings["billing_interval"])
      end

      {
        source: "revenuecat_local",
        active_subscriptions: users.count,
        estimated_mrr_cents: total_monthly_cents,
        estimated_mrr_usd: (total_monthly_cents / 100.0).round(2),
        plan_breakdown: plan_counts.sort_by { |_, v| -v }.to_h,
      }
    end

    private

    def revenuecat_paid_users
      User.non_admin
          .where(plan_type: %w[basic pro])
          .where(plan_status: ACTIVE_STATUSES)
          .where(stripe_subscription_id: [nil, ""])
    end

    def estimated_monthly_cents(plan_type, billing_interval)
      if billing_interval == "yearly"
        yearly = ESTIMATED_YEARLY_PRICES_CENTS[plan_type] || 0
        (yearly / 12.0).round
      else
        ESTIMATED_MONTHLY_PRICES_CENTS[plan_type] || 0
      end
    end
  end
end
