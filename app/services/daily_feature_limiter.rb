# app/services/daily_feature_limiter.rb
class DailyFeatureLimiter
  def initialize(user_id:, feature_key:, limit: 5, tz: "UTC", window: :day)
    Rails.logger.debug "Initializing DailyFeatureLimiter for User ID: #{user_id}, Feature: #{feature_key}, Limit: #{limit}, Timezone: #{tz}, Window: #{window}"
    @user_id = user_id
    @feature = feature_key.to_s
    @limit = limit
    @tz = ActiveSupport::TimeZone[tz] || Time.zone
    @window = window # :day (calendar) or :rolling_24h
  end

  def key(now = Time.current)
    stamp = if @window == :day
        now.in_time_zone(@tz).strftime("%Y%m%d")
      else
        # rolling window bucketed per-hour to keep TTL simple
        (now.to_i / 3600).to_i # optional; not needed for :day
      end
    "rl:#{@user_id}:#{@feature}:#{stamp}"
  end

  def increment_and_check!
    k = key
    c = Redis.current.incr(k)

    # set expiry on first use
    if c == 1
      if @window == :day
        eod = Time.current.in_time_zone(@tz).end_of_day
        Redis.current.expireat(k, eod.to_i)
      else
        Redis.current.expire(k, 24.hours.to_i)
      end
    end

    allowed = c <= @limit
    [allowed, remaining: [@limit - c, 0].max, used: c, limit: @limit, reset_at: reset_at]
  end

  def reset_at
    (@window == :day ? Time.current.in_time_zone(@tz).end_of_day : 24.hours.from_now)
  end
end
