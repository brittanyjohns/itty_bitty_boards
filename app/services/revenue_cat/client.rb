# frozen_string_literal: true

require "faraday"

module RevenueCat
  # Thin REST client for RevenueCat's v1 API. Used to verify, server-side, that
  # a user actually owns the entitlement they claim — so we never flip a
  # plan_type on client trust alone. v1 returns entitlements as an object keyed
  # by entitlement id with ISO8601 `expires_date` strings (webhooks, by
  # contrast, deliver epoch-millisecond timestamps — see WebhookProcessor).
  class Client
    API_HOST = "https://api.revenuecat.com"

    Result = Struct.new(
      :ok?, :plan_type, :active_entitlements, :expiration, :raw, :error,
      keyword_init: true,
    )

    def initialize(api_key: ENV["REVENUECAT_REST_API_KEY"])
      @api_key = api_key
    end

    # Look up the subscriber and return the verified plan_type (normalized
    # "basic"/"pro") plus the latest active-entitlement expiration. ok? is false
    # when the key is unconfigured, the request fails, or the user has no
    # subscriber record — callers treat any non-ok result as "unverified".
    def verified_plan_for(app_user_id)
      return Result.new(ok?: false, error: "missing_api_key") if @api_key.blank?

      response = connection.get("/v1/subscribers/#{app_user_id}") do |req|
        req.headers["Authorization"] = "Bearer #{@api_key}"
        req.headers["Accept"] = "application/json"
      end

      return Result.new(ok?: false, error: "http_#{response.status}") unless response.status == 200

      body = JSON.parse(response.body)
      entitlements = body.dig("subscriber", "entitlements") || {}
      active = entitlements.select { |_id, ent| active_entitlement?(ent) }

      plan_type = RevenueCat::PlanMapping.resolve_plan_type(entitlement_ids: active.keys)
      expiration = active.values.filter_map { |ent| parse_time(ent["expires_date"]) }.max

      Result.new(
        ok?: true,
        plan_type: plan_type,
        active_entitlements: active.keys,
        expiration: expiration,
        raw: body,
      )
    rescue => e
      Rails.logger.error "[RevenueCat::Client] verified_plan_for(#{app_user_id}) error: #{e.class} - #{e.message}"
      Result.new(ok?: false, error: e.message)
    end

    private

    # Active = no expiry (lifetime/non-expiring) or an expiry in the future.
    def active_entitlement?(ent)
      raw = ent["expires_date"]
      return true if raw.nil?

      expires = parse_time(raw)
      expires.present? && expires > Time.current
    end

    def parse_time(str)
      str.present? ? Time.iso8601(str) : nil
    rescue ArgumentError
      nil
    end

    def connection
      @connection ||= Faraday.new(url: API_HOST) do |f|
        f.options.timeout = 10
        f.options.open_timeout = 5
      end
    end
  end
end
