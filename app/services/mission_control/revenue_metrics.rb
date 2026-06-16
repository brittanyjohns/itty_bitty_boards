module MissionControl
  class RevenueMetrics
    def self.call = new.call

    def call
      stripe = StripeRevenueSource.call

      {
        active_subscriptions:   stripe[:active_subscriptions],
        estimated_mrr_cents:    stripe[:mrr_cents],
        mrr_usd:                stripe[:mrr_usd],
        new_subs_7d:            stripe[:new_subs_7d],
        revenue_source:         stripe[:source],
        revenue_cached_at:      stripe[:cached_at],
        revenue_error:          stripe[:error],
        stripe_plan_breakdown:  stripe[:plan_breakdown],
        paid_users:             User.non_admin.where.not(plan_type: ["free", nil]).count,
        free_users:             User.non_admin.where(plan_type: "free").count,
        plan_breakdown:         plan_breakdown,
      }
    end

    private

    def plan_breakdown
      User.non_admin
          .group(:plan_type)
          .count
          .sort_by { |_, v| -v }
          .to_h
    end
  end
end
