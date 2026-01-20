class PartnerMailer < ApplicationMailer
  def welcome_email(user)
    @user = user
    @start_date = Time.current
    @end_date = @start_date + 3.months
    @login_link = ENV["MARKETING_URL"] || "https://www.speakanyway.com"
    @partner_portal_url = ENV["PARTNER_PORTAL_URL"] || "https://www.speakanyway.com/partner-portal"

    mail(to: @user.email, subject: "Welcome to the SpeakAnyWay Partner Program!")
  end
end
