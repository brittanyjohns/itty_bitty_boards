class SetupMailer < BaseMailer
  default from: "SpeakAnyWay <noreply@speakanyway.com>"

  def myspeak_setup_email(user)
    @user = user
    slug = @user.slug
    @frontend_url = frontend_url
    @mymyspeak_link = @frontend_url + "/my/#{slug}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("setup_mailer.myspeak_setup_email.subject"))
    end
  end

  def vendor_setup_email(user)
    @user = user
    @frontend_url = frontend_url
    @vendors_dashboard_url = "#{@frontend_url}vendors/dashboard"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("setup_mailer.vendor_setup_email.subject"))
    end
  end

  def pro_setup_email(user)
    @user = user
    @frontend_url = frontend_url
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("setup_mailer.pro_setup_email.subject"))
    end
  end

  def basic_setup_email(user)
    @user = user
    @frontend_url = frontend_url
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("setup_mailer.basic_setup_email.subject"))
    end
  end
end
