require "net/http"
require "json"

# Verifies a Google-issued ID token server-side via Google's tokeninfo
# endpoint (https://oauth2.googleapis.com/tokeninfo). This is Google's own
# documented low-volume verification path — no JWKS/signature handling to
# hand-roll, and omniauth-google-oauth2's built-in verification is wired
# into the full OmniAuth request/callback middleware, which this app's
# bearer-token API auth doesn't use.
class GoogleIdTokenVerifier
  TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo"

  Result = Struct.new(:sub, :email, keyword_init: true)

  def self.verify(id_token)
    return nil if id_token.blank?

    client_id = ENV["GOOGLE_OAUTH_CLIENT_ID"]
    return nil if client_id.blank?

    uri = URI(TOKENINFO_URL)
    uri.query = URI.encode_www_form(id_token: id_token)
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
    return nil unless payload["aud"] == client_id
    return nil unless payload["email_verified"].to_s == "true"
    return nil if payload["sub"].blank? || payload["email"].blank?

    Result.new(sub: payload["sub"], email: payload["email"].to_s.downcase)
  rescue JSON::ParserError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "GoogleIdTokenVerifier: verification failed: #{e.class}: #{e.message}"
    nil
  end
end
