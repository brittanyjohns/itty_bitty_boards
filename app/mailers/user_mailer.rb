class UserMailer < BaseMailer
  def welcome_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/dashboard"
    subject = "Welcome to SpeakAnyWay AAC!"
    mail(to: @user.email, subject: subject, from: "hello@speakanyway.com")
  end

  def welcome_invitation_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/welcome/token/#{user.raw_invitation_token}"
    subject = "Welcome to SpeakAnyWay AAC!"
    mail(to: @user.email, subject: subject, from: "hello@speakanyway.com")
  end
end
