class CommunicationAccountMailer < ApplicationMailer
  def setup_email(account, sending_user = nil)
    @account = account
    @email = @account.email
    @sending_user = sending_user
    @startup_url = @account.startup_url
    @password = @account.passcode
    title = "Welcome to SpeakAnyWay AAC!"
    mail(to: @email, subject: title)
  end
end
