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
