# Geocoder is used only for **coarse, city-level** IP geolocation on safety-
# profile view alerts (see IpGeolocation + RecordProfileViewJob). It is never
# used for street-level lookups.
#
# The lookup runs inside a Sidekiq job, so a slow or failing provider can never
# block or break the public emergency page — IpGeolocation rescues everything
# and returns nil, in which case the alert email simply omits the location.
#
# Provider is ENV-tunable so production can point at a keyed service
# (e.g. ipinfo.io) without a code change. Defaults to the free, no-key
# `ipinfo_io` lookup for development.
Geocoder.configure(
  ip_lookup: (ENV["GEOCODER_IP_LOOKUP"] || "ipinfo_io").to_sym,
  timeout: (ENV["GEOCODER_TIMEOUT"] || 3).to_i,
  units: :km,
  # An API token for the configured IP provider, when one is required.
  ipinfo_io: { api_key: ENV["IPINFO_API_KEY"] },
)
