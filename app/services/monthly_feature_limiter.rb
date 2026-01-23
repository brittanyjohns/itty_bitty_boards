# app/services/monthly_feature_limiter.rb
class MonthlyFeatureLimiter
  DEFAULT_TIME = 30.days

  def initialize(user_id:, feature_key:, limit: 5, tz: "UTC", window: :month)
    @user_id = user_id
    @feature = feature_key.to_s
    @feature_long_name = feature_name(feature_key)
    @limit = limit
    @tz = ActiveSupport::TimeZone[tz] || Time.zone
    @window = window # :month
  end

  def key(now = Time.current)
    stamp = now.in_time_zone(@tz).strftime("%Y%m")

    "rl:#{@user_id}:#{@feature}:#{stamp}"
  end

  def feature_name(feature_key)
    case feature_key.to_s
    when "image_edits"
      "Image Edits"
    when "image_variations"
      "Image Variations"
    else
      feature_key.to_s.humanize
    end
  end

  def increment_and_check!
    k = key
    c = Redis.current.incr(k)

    # set expiry on first use
    if c == 1
      if @window == :month
        eom = Time.current.in_time_zone(@tz).end_of_month
        Redis.current.expireat(k, eom.to_i)
      else
        Redis.current.expire(k, DEFAULT_TIME.to_i)
      end
    end

    allowed = c <= @limit
    [allowed, remaining: [@limit - c, 0].max, used: c, limit: @limit, reset_at: reset_at, feature: @feature_long_name]
  end

  def reset_at
    time_to_set = (@window == :month ? Time.current.in_time_zone(@tz).end_of_month : DEFAULT_TIME.from_now)
  end
end
