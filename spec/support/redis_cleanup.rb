RSpec.configure do |config|
  config.before(:each) do
    Redis.current.flushdb if defined?(Redis) && Redis.respond_to?(:current)
  end
end
