# frozen_string_literal: true

# Helpers for exercising the RevenueCat webhook (API::BillingController#webhooks).
module RevenueCatHelpers
  RC_TEST_SECRET = "rc_test_secret_header"

  def rc_auth_headers(secret = RC_TEST_SECRET)
    { "Authorization" => secret, "Content-Type" => "application/json" }
  end

  # Build a RevenueCat webhook event envelope. Pass plan-shaping overrides as
  # string keys under the inner "event" (e.g. "entitlement_ids", "product_id",
  # "environment", "expiration_at_ms").
  def rc_event(type:, app_user_id:, id: "rc_evt_#{SecureRandom.hex(6)}", **overrides)
    {
      "event" => {
        "id" => id,
        "type" => type,
        "environment" => "PRODUCTION",
        "app_user_id" => app_user_id.to_s,
        "product_id" => "pro_monthly",
        "entitlement_ids" => ["pro"],
        "expiration_at_ms" => ((Time.current + 30.days).to_f * 1000).to_i,
        "store" => "APP_STORE",
      }.merge(overrides.transform_keys(&:to_s)),
    }
  end

  def post_rc_webhook(event_hash, headers: rc_auth_headers)
    post "/api/billing/webhooks", params: event_hash.to_json, headers: headers
  end
end

RSpec.configure do |config|
  config.include RevenueCatHelpers

  config.before do
    ENV["REVENUECAT_WEBHOOK_AUTH_HEADER"] = RevenueCatHelpers::RC_TEST_SECRET
  end
end
