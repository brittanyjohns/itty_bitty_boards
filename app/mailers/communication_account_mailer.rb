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

  # B4: SLP → family hand-off invite. Sends the parent the claim URL.
  def claim_link_email(account, recipient_email, sending_user = nil)
    @account = account
    @sending_user = sending_user
    @claim_url = account.claim_link_url
    @owner_name = sending_user&.display_name || account.owner&.display_name
    @child_name = account.display_name
    subject = "#{@owner_name || "Your therapist"} sent you a SpeakAnyWay communicator"
    mail(to: recipient_email, subject: subject)
  end
end
