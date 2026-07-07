# frozen_string_literal: true

# Rate limiting for SpeakAnyWay (issue #30).
#
# The Rack::Attack middleware is inserted automatically by the gem's Railtie
# (rack-attack >= 5), so there is no `config.middleware.use Rack::Attack` here —
# a manual insert would double-count every request.
#
# Scope is deliberately narrow: only WRITE / auth / AI-generation abuse
# surfaces are throttled. This is an AAC app — the read / board-load / audio
# *playback* paths a nonspeaking user hits constantly (e.g. `GET
# /api/audio/play`, board reads) are left untouched so speech output never
# breaks. When in doubt, a route is left unthrottled.
#
# Throttled requests get a clean 429 with a Retry-After header and a generic
# JSON body (no internals leaked). All limits are ENV-tunable with sensible
# defaults.

class Rack::Attack
  # --- Tunable limits (ENV-overridable, sensible defaults) ------------------

  def self.env_int(name, default)
    Integer(ENV.fetch(name, default.to_s))
  rescue ArgumentError, TypeError
    default
  end

  # Auth / sign-in (per IP + per email) — blunt brute force.
  LOGIN_LIMIT           = env_int("RACK_ATTACK_LOGIN_LIMIT", 20)
  LOGIN_EMAIL_LIMIT     = env_int("RACK_ATTACK_LOGIN_EMAIL_LIMIT", 10)
  LOGIN_PERIOD          = env_int("RACK_ATTACK_LOGIN_PERIOD", 60)

  # Password reset (per IP) — tighter, low-frequency.
  PASSWORD_RESET_LIMIT  = env_int("RACK_ATTACK_PASSWORD_RESET_LIMIT", 5)
  PASSWORD_RESET_PERIOD = env_int("RACK_ATTACK_PASSWORD_RESET_PERIOD", 3600)

  # Token-access lookups (per IP) — temp-login / communicator-claim links.
  TOKEN_LIMIT           = env_int("RACK_ATTACK_TOKEN_LIMIT", 20)
  TOKEN_PERIOD          = env_int("RACK_ATTACK_TOKEN_PERIOD", 60)

  # AI / audio generation (per user) — these gate on credit balance only, so
  # add a per-request-frequency ceiling on top.
  AI_LIMIT              = env_int("RACK_ATTACK_AI_LIMIT", 30)
  AI_PERIOD             = env_int("RACK_ATTACK_AI_PERIOD", 60)

  # Public profile lookups (per IP) — existing anti-enumeration limits.
  PROFILE_PUBLIC_LIMIT  = env_int("RACK_ATTACK_PROFILE_PUBLIC_LIMIT", 30)
  PROFILE_SLUG_LIMIT    = env_int("RACK_ATTACK_PROFILE_SLUG_LIMIT", 10)
  PROFILE_PERIOD        = env_int("RACK_ATTACK_PROFILE_PERIOD", 60)

  # --- Path matchers --------------------------------------------------------

  # POST sign-in surfaces: web devise, JSON API, and child passcode login.
  LOGIN_PATHS = %r{\A/(users/sign_in|api/v1/users/sign_in|api/v1/child_accounts/login)(\.\w+)?\z}

  # POST password-reset surfaces.
  PASSWORD_RESET_PATHS = %r{\A/api/v1/(forgot_password|reset_password|reset_password_invite)(\.\w+)?\z}

  # Access-granting token lookups (enumeration-sensitive). Deliberately does
  # NOT include `GET /api/generated_boards/:token` — the frontend polls that
  # while a board renders, and throttling it could break generation.
  TOKEN_ACCESS_PATHS = %r{\A/api/(temp-login|communicator_claims)/}

  # AI-generation path suffixes (the issue's `/generate*` + audio generation).
  AI_GEN_SUFFIXES = %w[generate generate_audio generate_preview_image regenerate_images].freeze

  # --- Discriminator helpers ------------------------------------------------

  # Per-user key from the API auth token (a stable `authentication_token` sent
  # in the Authorization header — see API::ApplicationController#token). Hashed
  # so no secret ever lands in a Redis key or log. Falls back to IP for
  # unauthenticated callers.
  def self.user_discriminator(req)
    token = req.get_header("HTTP_AUTHORIZATION").to_s.split(" ").last
    if token.present?
      "user:#{Digest::SHA256.hexdigest(token)[0, 20]}"
    else
      "ip:#{req.ip}"
    end
  end

  # Email for per-account login throttling. Handles both form-encoded devise
  # posts (`user[email]`) and the JSON API (`{ "email": ... }`). Reads and
  # rewinds the request body so the controller still sees it. Any parse
  # failure yields nil (no email throttle for that request).
  def self.login_email(req)
    email = req.params["email"] || req.params.dig("user", "email")
    email ||= json_body_email(req)
    normalized = email.to_s.strip.downcase
    normalized.presence
  rescue StandardError
    nil
  end

  def self.json_body_email(req)
    return nil unless req.content_type.to_s.include?("json")

    body = req.body.read
    req.body.rewind
    return nil if body.blank?

    parsed = JSON.parse(body)
    return nil unless parsed.is_a?(Hash)

    parsed["email"] || parsed.dig("user", "email")
  rescue StandardError
    nil
  end

  def self.ai_generation_request?(req)
    return false unless req.post?

    path = req.path.sub(/\.\w+\z/, "")
    return false unless path.start_with?("/api/")
    return false if path.start_with?("/api/internal/") # server-to-server, key-gated

    return true if path == "/api/generated_boards"

    AI_GEN_SUFFIXES.any? { |suffix| path.end_with?("/#{suffix}") }
  end

  # --- Safelists ------------------------------------------------------------

  # Never throttle the health check — BetterStack hits /up every 3 minutes.
  safelist("health-check") do |req|
    req.path == "/up" || req.path.start_with?("/up/")
  end

  # --- Throttles: auth ------------------------------------------------------

  throttle("login/ip", limit: LOGIN_LIMIT, period: LOGIN_PERIOD) do |req|
    req.ip if req.post? && req.path.match?(LOGIN_PATHS)
  end

  throttle("login/email", limit: LOGIN_EMAIL_LIMIT, period: LOGIN_PERIOD) do |req|
    login_email(req) if req.post? && req.path.match?(LOGIN_PATHS)
  end

  throttle("password_reset/ip", limit: PASSWORD_RESET_LIMIT, period: PASSWORD_RESET_PERIOD) do |req|
    req.ip if req.post? && req.path.match?(PASSWORD_RESET_PATHS)
  end

  # --- Throttles: token-access lookups -------------------------------------

  throttle("token_access/ip", limit: TOKEN_LIMIT, period: TOKEN_PERIOD) do |req|
    req.ip if req.path.match?(TOKEN_ACCESS_PATHS)
  end

  # --- Throttles: AI / audio generation (per user) -------------------------

  throttle("ai_generation/user", limit: AI_LIMIT, period: AI_PERIOD) do |req|
    user_discriminator(req) if ai_generation_request?(req)
  end

  # --- Throttles: public profile enumeration (existing) --------------------

  # Public profile lookup — generous enough for normal browsing but stops
  # automated scraping.
  throttle("public_profile/ip", limit: PROFILE_PUBLIC_LIMIT, period: PROFILE_PERIOD) do |req|
    if req.path.match?(%r{\A/api/profiles/public(/|\z)}) && req.get?
      req.ip
    end
  end

  # Slug availability check — tighter limit since it's only used during
  # onboarding / profile editing, not normal page views.
  throttle("check_slug/ip", limit: PROFILE_SLUG_LIMIT, period: PROFILE_PERIOD) do |req|
    if req.path.match?(%r{\A/api/profiles/check_slug(/|\z)}) && req.get?
      req.ip
    end
  end

  ### Custom response ###

  # Clean 429 with Retry-After. Generic body — never leak which rule matched
  # or any internals to the client.
  self.throttled_responder = lambda do |req|
    match_data = req.env["rack.attack.match_data"] || {}
    period = match_data[:period].to_i
    period = 60 if period <= 0
    retry_after = period - (Time.now.to_i % period)

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

# --- Counter store -----------------------------------------------------------
#
# Rack::Attack needs a real store to count against. The app's Rails.cache is
# :null_store in test (and toggled in dev), which would silently disable every
# throttle. Point Rack::Attack at Redis explicitly — the app already runs it.
# The error handler keeps a Redis blip from 500ing a request (fail open).
Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV.fetch("RACK_ATTACK_REDIS_URL", ENV.fetch("REDIS_URL", "redis://localhost:6379/0")),
  namespace: "rack_attack",
  error_handler: lambda { |method:, returning:, exception:|
    Rails.logger.warn("[rack-attack] cache #{method} error: #{exception.class}")
  }
)

# Opt out of throttling in the test environment by default so the existing
# request specs aren't affected by these limits; the rack_attack spec enables
# it explicitly (and swaps in a MemoryStore).
Rack::Attack.enabled = !Rails.env.test?

# Lightweight, non-leaking observability: log throttled requests so ops can see
# abuse without exposing anything to the client.
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  next unless req

  matched = req.env["rack.attack.matched"]
  Rails.logger.warn("[rack-attack] throttled rule=#{matched} ip=#{req.ip} path=#{req.path}")
end
