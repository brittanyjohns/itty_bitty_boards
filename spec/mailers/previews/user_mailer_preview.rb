# Preview all emails at http://localhost:3000/rails/mailers/user_mailer
class UserMailerPreview < ActionMailer::Preview
  def welcome_email
    @user = User.first
    UserMailer.welcome_email(@user)
  end

  def welcome_invitation_email
    @user = User.first
    UserMailer.welcome_invitation_email(@user)
  end
end
