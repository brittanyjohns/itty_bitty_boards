class AdminMailer < BaseMailer
  # Admin alert for a genuinely new account. Fired ONLY by
  # User#notify_admin_of_signup!, never from a welcome-email method — see that
  # method's comment for why.
  def new_user_email(user)
    @user = user
    @signup_platform = user.settings&.dig("signup_platform") || "unknown"
    @signup_method = user.settings&.dig("signup_method") || "unknown"
    @location = signup_location(user)
    subject = admin_subject(
      "New signup: #{user.email} (#{user.plan_type} · #{@signup_platform})",
    )
    mail(to: admin_recipient, subject: subject, from: "noreply@speakanyway.com")
  end

  def new_feedback_email(feedback_item)
    to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
    subject = "New feedback received for SpeakAnyWay AAC!!"
    @feedback_item = feedback_item
    @admin = User.find_by(id: User::DEFAULT_ADMIN_ID)
    mail(to: to_email, subject: subject, from: "noreply@speakanyway.com")
  end

  # Partner-pilot review digest, sent by PartnerPilotEndingJob when there are
  # partners ending soon and/or newly past their 3-month window. Gives Brittany
  # a single actionable list — nobody is auto-downgraded, so this is the signal
  # to convert / extend / downgrade each partner by hand.
  def partner_pilot_review(expiring:, expired:)
    to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
    @expiring = expiring || []
    @expired = expired || []
    subject = "Partner pilots: #{@expired.size} ended, #{@expiring.size} ending soon"
    mail(to: to_email, subject: subject, from: "noreply@speakanyway.com")
  end

  # Server disk-space alert, sent by DiskSpaceAlertJob.
  def disk_space_alert(usage:, severity:)
    to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
    @usage = usage
    @severity = severity
    @host = Socket.gethostname
    prefix = severity == :critical ? "CRITICAL" : "WARNING"
    subject = "[#{prefix}] SpeakAnyWay server disk at #{usage}%"
    mail(to: to_email, subject: subject, from: "noreply@speakanyway.com")
  end

  private

  def admin_recipient
    ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
  end

  # Staging runs with RAILS_ENV=production and the same ADMIN_EMAIL, so tag the
  # subject rather than suppressing the send — that keeps these alerts
  # verifiable end-to-end on staging without them reading as production signups.
  def admin_subject(text)
    AppEnv.staging? ? "[STAGING] #{text}" : text
  end

  # Coarse city-level location for the signup IP. Runs inside the deliver_later
  # job, never on the request path. IpGeolocation.coarse is total — it returns
  # nil for a private/unparseable IP or any provider error — and the template
  # drops the whole row when this is nil.
  def signup_location(user)
    ip = user.current_sign_in_ip.presence || user.last_sign_in_ip.presence
    return nil if ip.blank?
    IpGeolocation.coarse(ip)
  end
end
