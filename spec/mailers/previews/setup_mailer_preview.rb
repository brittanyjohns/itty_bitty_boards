# Preview all emails at http://localhost:3000/rails/mailers/setup_mailer
class SetupMailerPreview < ActionMailer::Preview
  def myspeak_setup_email
    user = User.find(User::DEFAULT_ADMIN_ID)
    SetupMailer.myspeak_setup_email(user)
  end

  def vendor_setup_email
    user = User.find(User::DEFAULT_ADMIN_ID)
    SetupMailer.vendor_setup_email(user)
  end

  def pro_setup_email
    user = User.find(User::DEFAULT_ADMIN_ID)
    SetupMailer.pro_setup_email(user)
  end

  def basic_setup_email
    user = User.find(User::DEFAULT_ADMIN_ID)
    SetupMailer.basic_setup_email(user)
  end

  def free_setup_email
    user = User.find(User::DEFAULT_ADMIN_ID)
    SetupMailer.basic_setup_email(user) # Assuming basic setup is the same for free users
  end
end
