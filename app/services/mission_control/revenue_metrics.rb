module MissionControl
  class RevenueMetrics
    def self.call = new.call

    def call
      {
        active_subscriptions:   Subscription.active.count,
        new_subs_today:         Subscription.where(created_at: today).count,
        new_subs_30d:           Subscription.where(created_at: 30.days.ago..).count,
        canceled_30d:           Subscription.canceled.where(updated_at: 30.days.ago..).count,
        paid_users:             User.non_admin.where.not(plan_type: ["free", nil]).count,
        free_users:             User.non_admin.where(plan_type: "free").count,
        plan_breakdown:         plan_breakdown,
        estimated_mrr_cents:    estimated_mrr_cents,
      }
    end

    private

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end

    def plan_breakdown
      User.non_admin
          .group(:plan_type)
          .count
          .sort_by { |_, v| -v }
          .to_h
    end

    def estimated_mrr_cents
      Subscription.active.sum(:price_in_cents)
    end
  end
end
