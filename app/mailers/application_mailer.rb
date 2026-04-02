class ApplicationMailer < ActionMailer::Base
  default from: "noreply@speakanyway.com"
  layout "mailer"

  def initialize(*args)
    super
    logo
    myspeak_logo
  end

  def logo
    attachments.inline["logo.png"] =
      File.read(Rails.root.join("public/logo_bubble.png"))
    @logo = attachments["logo.png"]
  end

  def myspeak_logo
    attachments.inline["myspeak_logo.png"] =
      File.read(Rails.root.join("public/myspeak_logo.png"))
    @myspeak_logo = attachments["myspeak_logo.png"]
  end
end
