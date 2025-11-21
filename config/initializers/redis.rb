# config/initializers/redis.rb
require "redis"

class << Redis
  attr_accessor :current
end

Redis.current = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
