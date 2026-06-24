# Records a single public view of a safety (communicator) profile page and,
# when appropriate, alerts the parent (issue #384).
#
# Enqueued (fire-and-forget) from API::ProfilesController#public for safety
# profiles only. All the work that could be slow or fail — geolocation, email —
# happens here, off the request, so the public emergency page always loads fast
# and is never broken by this feature.
#
# Flow:
#   1. Bail unless this is a safety profile with an owner to notify.
#   2. Coarse IP→location lookup (best-effort; nil on any failure).
#   3. Always persist a ProfileView (the audit log for abuse-pattern detection).
#   4. Throttle: at most ONE alert per profile per hour (atomic Redis claim).
#   5. Skip the alert (but keep the log) if the parent opted out or has
#      notifications globally disabled.
#   6. Otherwise deliver via Notifications::SafetyViewNotifier and mark the
#      ProfileView notified.
class RecordProfileViewJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 1

  NOTIFY_THROTTLE_WINDOW = (ENV["SAFETY_VIEW_THROTTLE_SECONDS"] || 1.hour.to_i).to_i

  def perform(profile_id, ip_address = nil, user_agent = nil)
    profile = Profile.find_by(id: profile_id)
    return if profile.nil? || !profile.safety?

    owner = profile.alert_recipient

    # Always log the raw view (IP + timestamp) for the abuse-pattern history.
    profile_view = profile.profile_views.create!(
      ip_address: ip_address,
      user_agent: user_agent,
      viewed_at: Time.current,
      notified: false,
    )

    return if owner.nil?
    return unless profile.view_alerts_enabled?
    return if owner_disabled_all_notifications?(owner)
    return unless claim_notify_slot(profile.id)

    # Geolocation runs only once we're actually going to notify — so the
    # external lookup happens at most once per profile per hour, not on every
    # bot/scan that hits the public page.
    geo = IpGeolocation.coarse(ip_address)
    profile_view.update!(
      approx_location: geo&.dig(:label),
      geo: geo ? geo.except(:label) : {},
      notified: true,
    )

    Notifications::SafetyViewNotifier.deliver(
      profile: profile,
      profile_view: profile_view,
      owner: owner,
    )
  end

  private

  # Respect the user's global notification kill-switch (the same
  # settings["disable_notifications"] flag User#should_receive_notifications?
  # reads). We deliberately do NOT reuse that helper here: it also enforces an
  # unrelated cross-feature 2-hour throttle that could silently swallow a safety
  # alert because the parent happened to get some other email recently. The
  # per-profile hourly throttle below is the only timing gate that should apply.
  def owner_disabled_all_notifications?(owner)
    settings = owner.settings || {}
    [true, "true", "1", 1].include?(settings["disable_notifications"])
  end

  # Atomic per-profile debounce so concurrent views can't each fire an email.
  # Mirrors DiskSpaceAlertJob's Redis SET NX EX pattern.
  def claim_notify_slot(profile_id)
    result = Sidekiq.redis do |conn|
      conn.call(
        "SET", "safety_view_notify:#{profile_id}", Time.current.to_i,
        "NX", "EX", NOTIFY_THROTTLE_WINDOW
      )
    end
    result == "OK"
  end
end
