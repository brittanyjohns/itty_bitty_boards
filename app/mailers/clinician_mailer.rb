# Emails for the SpeakAnyWay for Clinicians program. Warm, plain-English, in the
# PartnerMailer voice. Never use the word "Professional" (it collides with the
# Pro tier) — always "Clinician account" / "SpeakAnyWay for Clinicians".
class ClinicianMailer < BaseMailer
  # Sent when an application is submitted — confirms we received it and sets the
  # "we review by hand" expectation.
  def application_received_email(application)
    @application = application
    @user = application.user
    @user_name = @user.name.presence || application.full_name
    @front_end_url = frontend_url

    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("clinician_mailer.application_received_email.subject"))
    end
  end

  # Sent when an admin approves — the account is now a free Clinician account.
  def approved_email(application)
    @application = application
    @user = application.user
    @user_name = @user.name.presence || application.full_name
    @front_end_url = frontend_url
    @sign_in_url = "#{@front_end_url}/users/sign-in?email=#{CGI.escape(@user.email)}"

    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("clinician_mailer.approved_email.subject"))
    end
  end

  # Sent when an admin denies — kind, leaves the door open to re-apply. Includes
  # the admin's optional note when present.
  def denied_email(application)
    @application = application
    @user = application.user
    @user_name = @user.name.presence || application.full_name
    @note = application.notes.presence
    @front_end_url = frontend_url

    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("clinician_mailer.denied_email.subject"))
    end
  end
end
