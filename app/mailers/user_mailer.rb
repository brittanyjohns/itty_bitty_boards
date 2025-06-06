class UserMailer < BaseMailer
  def welcome_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/welcome/token/#{user.raw_invitation_token}"
    @login_link += "?email=#{user.email}"
    subject = "Welcome to SpeakAnyWay AAC!"
    mail(to: @user.email, subject: subject, from: "noreply@speakanyway.com")
  end

  def welcome_invitation_email(user, inviter_id)
    @user = user
    @user_name = @user.name
    @inviter = User.find(inviter_id&.to_i)
    @inviter_name = @inviter.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/welcome/token/#{user.raw_invitation_token}"
    subject = "You have been invited to join SpeakAnyWay AAC!"
    Rails.logger.info "Sending welcome invitation email to #{user.email} from #{inviter_id}"
    Rails.logger.info "Login link: #{@login_link}"
    mail(to: @user.email, subject: subject, from: "noreply@speakanyway.com")
  end

  def welcome_to_organization_email(user, organization)
    @user = user
    @user_name = @user.name
    @organization = organization
    @organization_name = @organization.name
    @organization_admin = @organization.admin_user
    @organization_admin_name = @organization_admin.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/welcome/token/#{user.raw_invitation_token}"
    @login_link += "?email=#{user.email}"
    subject = "You have been invited to join #{@organization_name} on SpeakAnyWay AAC!"
    Rails.logger.info "Sending welcome to organization email to #{@user.email} from #{@organization_admin.id}"
    Rails.logger.info "Login link: #{@login_link}"
    mail(to: @user.email, subject: subject, from: "noreply@speakanyway.com")
  end

  def welcome_with_claim_link_email(user, slug)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    if user.raw_invitation_token.nil?
      # Existing user, just need to login
      @login_link += "/users/sign-in/welcome/#{@user.email}"
      @login_link += "?claim=#{slug}"
    else
      token = user.raw_invitation_token
      @login_link += "/welcome/token/#{token}"
      @login_link += "?email=#{ERB::Util.url_encode(user.email)}&claim=#{slug}"
    end

    @claim_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @claim_link += "/claim/#{slug}"
    @mymyspeak_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @mymyspeak_link += "/my/#{slug}"
    subject = "Welcome to MySpeak - Claim your profile!"
    Rails.logger.info "Sending welcome email to #{@user.email} with claim link"
    mail(to: @user.email, subject: subject, from: "noreply@speakanyway.com")
  end

  def message_notification_email(message)
    @message = message
    @sender = message.sender
    @recipient = message.recipient
    @message_body = message.body
    @message_subject = message.subject
    @message_sent_at = message.sent_at
    @message_read_at = message.read_at
    @message_url = "#{ENV["FRONT_END_URL"]}/messages/#{message.id}"
    subject = "New message from #{@sender.name}"
    Rails.logger.info "Sending message notification email to #{@recipient.email}"
    mail(to: @recipient.email, subject: subject, from: "noreply@speakanyway.com")
  end
end
