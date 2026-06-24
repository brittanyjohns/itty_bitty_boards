# Coarse, city-level IP geolocation for safety-profile view alerts (issue #384).
#
# Wraps Geocoder so the rest of the app gets a tiny, safe surface: pass an IP,
# get back a plain hash (or nil). It NEVER raises — any provider error, timeout,
# private/loopback IP, or missing result yields nil, in which case the alert
# email simply omits the location. This must stay total: it runs off the public
# emergency page (via RecordProfileViewJob) and can never be allowed to break a
# notification.
module IpGeolocation
  module_function

  # Returns { city:, region:, country:, label: } or nil.
  # `label` is a human string like "Austin, Texas, US" suitable for an email.
  def coarse(ip)
    ip = ip.to_s.strip
    return nil if ip.blank? || private_or_local?(ip)

    result = Geocoder.search(ip).first
    return nil if result.nil?

    city    = presence(result.city)
    region  = presence(result.respond_to?(:state) ? result.state : nil)
    country = presence(result.country)
    label   = [city, region, country].compact.join(", ").presence
    return nil if label.nil?

    { city: city, region: region, country: country, label: label }
  rescue => e
    Rails.logger.warn("[IpGeolocation] lookup failed for #{ip}: #{e.class}: #{e.message}")
    nil
  end

  def private_or_local?(ip)
    addr = IPAddr.new(ip)
    addr.loopback? || addr.private? || addr.link_local?
  rescue IPAddr::Error
    true # unparseable → treat as unusable
  end

  def presence(value)
    value.to_s.strip.presence
  end
end
