class PartnerMailer < ApplicationMailer
  def welcome_email(user)
    @user = user
    @start_date = Time.current
    @end_date = @start_date + 3.months
    @partner_portal_url = ENV["PARTNER_PORTAL_URL"] || "https://www.speakanyway.com/partner-portal"
    @front_end_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @sign_in_url = "#{@front_end_url}/users/sign-in?email=#{CGI.escape(@user.email)}"

    mail(to: @user.email, subject: "Welcome to the SpeakAnyWay Partner Program!")
  end
end
