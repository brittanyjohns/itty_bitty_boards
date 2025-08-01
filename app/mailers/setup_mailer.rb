class SetupMailer < BaseMailer
  default from: "SpeakAnyWay <noreply@speakanyway.com>"

  def myspeak_setup_email(user)
    @user = user
    slug = @user.slug
    @frontend_url = frontend_url
    @mymyspeak_link = @frontend_url + "/my/#{slug}"
    mail(to: @user.email, subject: "MySpeaker Setup Instructions")
  end

  def vendor_setup_email(user)
    @user = user
    @frontend_url = frontend_url
    mail(to: @user.email, subject: "Vendor Setup Instructions")
  end

  def pro_setup_email(user)
    @user = user
    @frontend_url = frontend_url
    mail(to: @user.email, subject: "Pro Setup Instructions")
  end

  def basic_setup_email(user)
    @user = user
    @frontend_url = frontend_url
    mail(to: @user.email, subject: "Basic Setup Instructions")
  end
end
