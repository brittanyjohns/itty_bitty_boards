# Preview all emails at http://localhost:3000/rails/mailers/communication_account_mailer
class CommunicationAccountMailerPreview < ActionMailer::Preview
  def setup_email
    account = ChildAccount.first
    sending_user = account.user
    CommunicationAccountMailer.setup_email(account, sending_user)
  end
end
