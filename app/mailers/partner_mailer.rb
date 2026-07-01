class PartnerMailer < BaseMailer
  def welcome_email(user)
    @user = user
    @start_date = Time.current
    @end_date = @start_date + 3.months
    @partner_portal_url = ENV["PARTNER_PORTAL_URL"] || "https://www.speakanyway.com/partner-portal"
    @front_end_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @sign_in_url = "#{@front_end_url}/users/sign-in?email=#{CGI.escape(@user.email)}"

    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("partner_mailer.welcome_email.subject"))
    end
  end

  # "Your 3-month pilot is wrapping up" nudge, sent by PartnerPilotEndingJob
  # when a Partner Pro account is within the reminder lead window of its
  # plan_expires_at. Points the partner at their account and an easy way to
  # continue on a paid plan; the pilot does NOT auto-cancel, so the tone is a
  # heads-up, not a shutoff notice.
  def pilot_ending_email(user)
    @user = user
    @end_date = user.plan_expires_at
    @days_left = @end_date ? [((@end_date - Time.current) / 1.day).ceil, 0].max : nil
    @front_end_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @sign_in_url = "#{@front_end_url}/users/sign-in?email=#{CGI.escape(@user.email)}"
    @plans_url = "#{@front_end_url}/plans"
    @partner_portal_url = ENV["PARTNER_PORTAL_URL"] || "https://www.speakanyway.com/partner-portal"

    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("partner_mailer.pilot_ending_email.subject"))
    end
  end
end
