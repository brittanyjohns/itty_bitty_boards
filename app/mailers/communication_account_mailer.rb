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
  # random-slug migration), so the printed device tag's QR code is regenerated.
  # Tells the parent to download the refreshed tag. The method name is broader
  # than what it now covers — it also rebuilt the Safety ID card until that card
  # was retired — and is kept because RegenerateSafetyCardsJob and the template
  # share it.
  def safety_cards_updated(user, child_account)
    @user = user
    @child_account = child_account
    @profile = child_account.profile
    @child_name = child_account.display_name
    # /communicators/:id/... is not a route the frontend declares (and no
    # Netlify redirect covers it) — that URL 404s. The communicator screen
    # lives at /communicator-accounts/:id/:tab, and the device tag + safety
    # cards are in the "Print & share" section of the MySpeak tab.
    @download_url = "#{frontend_url}/communicator-accounts/#{child_account.id}/myspeak#print-share"

    with_user_locale(user) do
      mail(
        to: user.email,
        subject: "#{@child_name}'s device tag has been updated",
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
