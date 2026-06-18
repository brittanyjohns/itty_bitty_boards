module MissionControl
  class StripeRevenueSource
    CACHE_KEY = "mission_control/stripe_revenue".freeze
    CACHE_TTL = 10.minutes

    def self.call = new.call

    def self.clear_cache
      Rails.cache.delete(CACHE_KEY)
    end

    def call
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { fetch_from_stripe }
    rescue Stripe::StripeError => e
      Rails.logger.error("[MissionControl::StripeRevenueSource] Stripe error: #{e.message}")
      fallback_response(error: e.message)
    end

    private

    def fetch_from_stripe
      subs = fetch_all_active_subscriptions
      now = Time.current

      plan_counts = Hash.new(0)
      total_monthly_cents = 0
      new_in_7d = 0
      new_in_7d_by_plan = Hash.new(0)

      subs.each do |sub|
        plan_name = extract_plan_name(sub)
        plan_counts[plan_name] += 1
        total_monthly_cents += monthly_amount_cents(sub)
        if Time.at(sub.created) > 7.days.ago
          new_in_7d += 1
          new_in_7d_by_plan[plan_name] += 1
        end
      end

      {
        source: "stripe",
        cached_at: now.iso8601,
        active_subscriptions: subs.size,
        mrr_cents: total_monthly_cents,
        mrr_usd: (total_monthly_cents / 100.0).round(2),
        new_subs_7d: new_in_7d,
        new_subs_7d_by_plan: new_in_7d_by_plan.sort_by { |_, v| -v }.to_h,
        plan_breakdown: plan_counts.sort_by { |_, v| -v }.to_h,
      }
    end

    def fetch_all_active_subscriptions
      all = []
      params = { status: "active", limit: 100, expand: ["data.items.data.price"] }

      loop do
        batch = Stripe::Subscription.list(params)
        all.concat(batch.data)
        break unless batch.has_more
        params[:starting_after] = batch.data.last.id
      end

      trialing_params = { status: "trialing", limit: 100, expand: ["data.items.data.price"] }
      loop do
        batch = Stripe::Subscription.list(trialing_params)
        all.concat(batch.data)
        break unless batch.has_more
        trialing_params[:starting_after] = batch.data.last.id
      end

      all
    end

    def extract_plan_name(sub)
      item = sub.items.data.first
      return "unknown" unless item

      price = item.price
      price.metadata["plan_type"].presence || price.lookup_key.presence || price.id
    end

    def monthly_amount_cents(sub)
      item = sub.items.data.first
      return 0 unless item

      price = item.price
      amount = price.unit_amount || 0
      interval = price.recurring&.interval

      case interval
      when "year"
        (amount / 12.0).round
      when "month"
        amount
      else
        amount
      end
    end

    def fallback_response(error:)
      {
        source: "stripe",
        cached_at: nil,
        active_subscriptions: nil,
        mrr_cents: nil,
        mrr_usd: nil,
        new_subs_7d: nil,
        new_subs_7d_by_plan: {},
        plan_breakdown: {},
        error: error,
      }
    end
  end
end
