require "rails_helper"

# Coverage for issue #474: production had no explicit `config.cache_store`, so
# it fell back to Rails' default `:file_store` — per-box and unbounded under
# `tmp/cache` — while real code paths cache through `Rails.cache`. Production
# now uses a namespaced, fail-open Redis cache store (Redis already backs
# Sidekiq / Rack::Attack, so no new infrastructure).
#
# Rails only loads `config/environments/production.rb` when `Rails.env` is
# production, so we assert against the file's contents in an isolated context
# rather than flipping the environment under the test runner (mirrors
# production_smtp_timeouts_spec).
RSpec.describe "config/environments/production.rb cache store" do
  let(:production_env_path) { Rails.root.join("config/environments/production.rb") }
  let(:contents) { File.read(production_env_path) }

  it "configures a redis_cache_store" do
    expect(contents).to match(/config\.cache_store\s*=\s*:redis_cache_store/)
  end

  it "does not leave the cache store on the default (commented-out) line" do
    expect(contents).not_to match(/^\s*#\s*config\.cache_store\s*=/)
  end

  it "sources the Redis URL from ENV (no hardcoded production host)" do
    expect(contents).to match(/url:\s*ENV\.fetch\("CACHE_REDIS_URL"/)
    expect(contents).to match(/ENV\.fetch\("REDIS_URL"/)
  end

  it "namespaces the cache so keys can't collide with Sidekiq / Rack::Attack" do
    expect(contents).to match(/namespace:\s*"ibb_cache"/)
  end

  it "fails open with an error_handler so a Redis blip can't 500 a request" do
    expect(contents).to match(/error_handler:/)
  end
end
