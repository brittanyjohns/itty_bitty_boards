# Preview all emails at http://localhost:3000/rails/mailers/user_mailer
class UserMailerPreview < ActionMailer::Preview
  def welcome_email
    @user = User.first
    UserMailer.welcome_email(@user)
  end

  def welcome_invitation_email
    @user = User.first
    email = "bhannajohns+new_user@gmail.com"
    new_user = User.invite!(email: email, skip_invitation: true)
    UserMailer.welcome_invitation_email(new_user, @user.id)
  end

  def message_notification_email
    @message = Message.first
    @sender = @message.sender
    @recipient = @message.recipient
    UserMailer.message_notification_email(@message)
  end
end
