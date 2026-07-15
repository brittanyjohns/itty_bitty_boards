class ApplicationMailer < ActionMailer::Base
  default from: "noreply@speakanyway.com"
  layout "mailer"

  def initialize(*args)
    super
    logo
  end

  def logo
    attachments.inline["logo.png"] =
      File.read(Rails.root.join("public/logo_bubble.png"))
    @logo = attachments["logo.png"]
  end
end
