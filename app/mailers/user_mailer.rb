class UserMailer < BaseMailer
  def welcome_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/dashboard"
    subject = "Welcome to SpeakAnyWay!"
    mail(to: @user.email, subject: subject)
  end
end
