class PartnerMailer < ApplicationMailer
  def welcome_email(user)
    @user = user
    @start_date = Time.current
    @end_date = @start_date + 3.months

    mail(to: @user.email, subject: "Welcome to the SpeakAnyWay Partner Program!")
  end
end
