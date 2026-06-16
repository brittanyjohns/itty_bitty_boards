module Stats
  class StripeRevenue
    def self.call
      Rails.cache.fetch("stats/stripe_revenue", expires_in: 10.minutes) do
        new.fetch
      end
    end

    def fetch
      subscriptions = []
      Stripe::Subscription.list(status: "active", limit: 100).auto_paging_each do |sub|
        subscriptions << sub
      end

      seven_days_ago = 7.days.ago.to_i
      plan_counts = Hash.new(0)
      mrr_cents = 0

      subscriptions.each do |sub|
        item = sub.items.data.first
        next unless item&.price&.recurring

        price = item.price
        unit = price.unit_amount || 0
        qty = item.quantity || 1
        interval = price.recurring.interval
        interval_count = price.recurring.interval_count || 1

        monthly = case interval
                  when "month" then (unit * qty).to_f / interval_count
                  when "year"  then (unit * qty).to_f / (12 * interval_count)
                  when "week"  then (unit * qty).to_f * 52 / (12 * interval_count)
                  when "day"   then (unit * qty).to_f * 365 / (12 * interval_count)
                  else 0
                  end

        mrr_cents += monthly
        name = price.nickname.presence || price.id
        plan_counts[name] += 1
      end

      {
        source: "stripe",
        cached_at: Time.current.iso8601,
        active_subscriptions: subscriptions.size,
        mrr_usd: (mrr_cents / 100.0).round(2),
        new_subs_7d: subscriptions.count { |s| s.created >= seven_days_ago },
        plan_breakdown: plan_counts.sort_by { |_, v| -v }.to_h,
      }
    rescue Stripe::StripeError => e
      Rails.logger.error("Stats::StripeRevenue failed: #{e.message}")
      {
        source: "stripe",
        error: true,
        cached_at: Time.current.iso8601,
        active_subscriptions: nil,
        mrr_usd: nil,
        new_subs_7d: nil,
        plan_breakdown: nil,
      }
    end
  end
end
