# A long-lived OAuth grant held on behalf of the app itself (not a user), for
# providers whose refresh token ROTATES and therefore cannot live in ENV.
#
# Etsy is the motivating case: every refresh exchange invalidates the token
# that was used and returns a new one, so a token pinned in Hatchbox ENV is
# dead after the first exchange. It has to be written back somewhere, and the
# database is the only writable store this app has.
#
# The corollary is that two systems must never share one grant. The
# speakanyway-printables repo holds its own Etsy refresh token in its .env; if
# Rails exchanged that same token the two would invalidate each other and both
# would start throwing intermittent 403s. Rails therefore uses a SEPARATE
# authorization of the same Etsy app — see `rake etsy:seed_refresh_token`.
#
# Tokens are stored in plaintext: ActiveRecord encryption is not configured in
# this app, and quietly introducing encryption keys here is a bigger decision
# than this table. Access is admin-only and the value is filtered out of logs
# below; revisit if AR encryption is ever turned on.
class OauthCredential < ApplicationRecord
  PROVIDER_ETSY = "etsy".freeze

  validates :provider, presence: true, uniqueness: true

  def self.for_provider(provider) = find_by(provider: provider)

  def self.upsert_refresh_token!(provider:, refresh_token:, metadata: {})
    record = find_or_initialize_by(provider: provider)
    record.refresh_token = refresh_token
    record.metadata = record.metadata.to_h.merge(metadata.stringify_keys)
    # A newly seeded refresh token invalidates whatever access token we cached.
    record.access_token = nil
    record.access_token_expires_at = nil
    record.save!
    record
  end

  # Treat a token as expired slightly early so a request that takes a moment to
  # reach the provider can't be issued with a token that dies in flight.
  EXPIRY_SKEW = 60.seconds

  def access_token_valid?
    access_token.present? && access_token_expires_at.present? &&
      access_token_expires_at > Time.current + EXPIRY_SKEW
  end

  # Never let a token reach a log line, an error report, or a console
  # transcript by way of the default attribute-dumping inspect.
  def inspect
    "#<OauthCredential id: #{id.inspect} provider: #{provider.inspect} [tokens redacted]>"
  end
end
