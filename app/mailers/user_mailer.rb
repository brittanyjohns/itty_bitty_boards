class UserMailer < BaseMailer
  def welcome_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/welcome/token/#{user.raw_invitation_token}"
    @login_link += "?email=#{user.email}"
    subject = "Welcome to SpeakAnyWay AAC!"
    mail(to: @user.email, subject: subject, from: "noreply@speakanyway.com")
  end

  def welcome_invitation_email(user, inviter_id)
    @user = user
    @user_name = @user.name
    @inviter = User.find(inviter_id&.to_i)
    @inviter_name = @inviter.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/welcome/token/#{user.raw_invitation_token}"
    subject = "You have been invited to join SpeakAnyWay AAC!"
    Rails.logger.info "Sending welcome invitation email to #{user.email} from #{inviter_id}"
    Rails.logger.info "Login link: #{@login_link}"
    mail(to: @user.email, subject: subject, from: "noreply@speakanyway.com")
  end
end
