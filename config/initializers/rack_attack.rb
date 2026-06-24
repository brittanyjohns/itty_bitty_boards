# frozen_string_literal: true

# Rate-limit public profile endpoints to prevent enumeration / scraping.
# These endpoints skip authentication, so IP-based throttling is the
# primary defence.
#
# Limits:
#   /api/profiles/public/:slug  — 30 req/min per IP
#   /api/profiles/check_slug    — 10 req/min per IP
#
# Blocked requests receive 429 Too Many Requests with a JSON body and a
# Retry-After header.

class Rack::Attack
  ### Throttles ###

  # Public profile lookup — generous enough for normal browsing but stops
  # automated scraping.
  throttle("public_profile/ip", limit: 30, period: 60) do |req|
    if req.path.match?(%r{\A/api/profiles/public(/|\z)}) && req.get?
      req.ip
    end
  end

  # Slug availability check — tighter limit since it's only used during
  # onboarding / profile editing, not normal page views.
  throttle("check_slug/ip", limit: 10, period: 60) do |req|
    if req.path.match?(%r{\A/api/profiles/check_slug(/|\z)}) && req.get?
      req.ip
    end
  end

  ### Custom response ###

  self.throttled_responder = lambda do |req|
    match_data = req.env["rack.attack.match_data"] || {}
    retry_after = (match_data[:period] || 60) - (Time.now.to_i % (match_data[:period] || 60))

    [
      429,
      {
        "Content-Type" => "application/json; charset=utf-8",
        "Retry-After" => retry_after.to_s,
      },
      [{ error: "rate_limited", retry_after: retry_after }.to_json],
    ]
  end
end
