class CommunicationAccountMailer < BaseMailer
  def setup_email(account, sending_user = nil)
    @account = account
    @email = @account.email
    @sending_user = sending_user
    @startup_url = @account.startup_url
    @password = @account.passcode
    with_user_locale(@account.owner) do
      mail(to: @email, subject: I18n.t("communication_account_mailer.setup_email.subject"))
    end
  end

  # Sent after a communicator's safety profile gets a new secure link (the
  # random-slug migration), so the printed safety ID card + device tag QR codes
  # are regenerated. Tells the parent to download the refreshed cards.
  def safety_cards_updated(user, child_account)
    @user = user
    @child_account = child_account
    @profile = child_account.profile
    @child_name = child_account.display_name
    @download_url = "#{frontend_url}/communicators/#{child_account.id}/safety"

    with_user_locale(user) do
      mail(
        to: user.email,
        subject: "#{@child_name}'s safety cards have been updated",
      )
    end
  end

  # B4: SLP → family hand-off invite. Sends the parent the claim URL.
  def claim_link_email(account, recipient_email, sending_user = nil)
    @account = account
    @sending_user = sending_user
    @claim_url = account.claim_link_url
    @owner_name = sending_user&.display_name || account.owner&.display_name
    @child_name = account.display_name
    with_user_locale(account.owner) do
      mail(
        to: recipient_email,
        subject: I18n.t(
          "communication_account_mailer.claim_link_email.subject",
          owner_name: @owner_name || I18n.t("communication_account_mailer.claim_link_email.default_owner_name"),
        ),
      )
    end
  end
end
