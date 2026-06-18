module MissionControl
  class RevenueMetrics
    def self.call = new.call

    def call
      stripe = StripeRevenueSource.call
      rc = RevenuecatRevenueSource.call

      stripe_subs = stripe[:active_subscriptions]
      rc_subs = rc[:active_subscriptions]
      combined_subs = safe_add(stripe_subs, rc_subs)

      stripe_mrr = stripe[:mrr_cents]
      rc_mrr = rc[:estimated_mrr_cents]
      combined_mrr = safe_add(stripe_mrr, rc_mrr)

      {
        active_subscriptions:   combined_subs,
        estimated_mrr_cents:    combined_mrr,
        mrr_usd:                combined_mrr ? (combined_mrr / 100.0).round(2) : nil,
        new_subs_7d:            stripe[:new_subs_7d],
        revenue_source:         "stripe+revenuecat",
        revenue_cached_at:      stripe[:cached_at],
        revenue_error:          stripe[:error],
        new_subs_7d_by_plan:    stripe[:new_subs_7d_by_plan] || {},
        stripe:                 {
          active_subscriptions: stripe_subs,
          mrr_cents:            stripe_mrr,
          mrr_usd:              stripe[:mrr_usd],
          plan_breakdown:       stripe[:plan_breakdown],
        },
        revenuecat:             {
          active_subscriptions: rc_subs,
          estimated_mrr_cents:  rc_mrr,
          estimated_mrr_usd:    rc[:estimated_mrr_usd],
          plan_breakdown:       rc[:plan_breakdown],
        },
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

    def safe_add(a, b)
      return nil if a.nil? && b.nil?
      (a || 0) + (b || 0)
    end
  end
end
