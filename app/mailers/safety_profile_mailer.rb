class SafetyProfileMailer < BaseMailer
  # Alerts a parent that their child's public safety page was viewed (issue
  # #384). Sent from Notifications::SafetyViewNotifier, which has already
  # applied the per-profile hourly throttle and the parent's opt-out.
  def viewed_alert(profile, profile_view)
    @profile = profile
    @owner = profile.alert_recipient
    return if @owner&.email.blank?

    @child_name = profile.safety_display_name
    # Unambiguous UTC stamp — the app stores timestamps in UTC and the parent's
    # timezone isn't known here.
    @viewed_at_display = profile_view.viewed_at.utc.strftime("%B %-d, %Y at %-l:%M %p UTC")
    @approx_location = profile_view.approx_location.presence
    @manage_url = "#{frontend_url}/dashboard/myspeak"

    with_user_locale(@owner) do
      mail(
        to: @owner.email,
        subject: I18n.t(
          "safety_profile_mailer.viewed_alert.subject",
          child_name: @child_name,
        ),
      )
    end
  end
end
