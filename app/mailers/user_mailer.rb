class UserMailer < BaseMailer
  default from: "SpeakAnyWay <noreply@speakanyway.com>"

  def welcome_free_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    if @user.raw_invitation_token.nil?
      @user = User.find(user.id) # Reload user to ensure raw_invitation_token is up-to-date
      @login_link += "/users/sign-in"
    else
      Rails.logger.info "User #{@user.id} already has a raw_invitation_token, using it for welcome link"
      token = @user.raw_invitation_token
      Rails.logger.info "User #{@user.id} has raw_invitation_token: #{token}"
      @login_link += "/welcome/token/#{token}"
    end

    encoded_email = ERB::Util.url_encode(@user.email)
    @login_link += "?email=#{encoded_email}"
    subject = "Welcome to SpeakAnyWay AAC!"
    Rails.logger.info "Sending welcome free email to #{@user.email} with login link: #{@login_link}"
    mail(to: @user.email, subject: subject)
  end

  def welcome_basic_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    if @user.raw_invitation_token.nil?
      @user = User.find(user.id) # Reload user to ensure raw_invitation_token is up-to-date
      @login_link += "/users/sign-in"
    else
      Rails.logger.info "User #{@user.id} already has a raw_invitation_token, using it for welcome link"
      token = @user.raw_invitation_token
      Rails.logger.info "User #{@user.id} has raw_invitation_token: #{token}"
      @login_link += "/welcome/token/#{token}"
    end

    encoded_email = ERB::Util.url_encode(@user.email)
    @login_link += "?email=#{encoded_email}"
    subject = "Welcome to SpeakAnyWay AAC!"
    Rails.logger.info "Sending welcome free email to #{@user.email} with login link: #{@login_link}"
    mail(to: @user.email, subject: subject)
  end

  def welcome_pro_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    if @user.raw_invitation_token.nil?
      @user = User.find(user.id) # Reload user to ensure raw_invitation_token is up-to-date
      @login_link += "/users/sign-in"
    else
      Rails.logger.info "User #{@user.id} already has a raw_invitation_token, using it for welcome link"
      token = @user.raw_invitation_token
      Rails.logger.info "User #{@user.id} has raw_invitation_token: #{token}"
      @login_link += "/welcome/token/#{token}"
    end

    encoded_email = ERB::Util.url_encode(@user.email)
    @login_link += "?email=#{encoded_email}"
    subject = "Welcome to SpeakAnyWay AAC!"
    Rails.logger.info "Sending welcome free email to #{@user.email} with login link: #{@login_link}"
    mail(to: @user.email, subject: subject)
  end

  # def welcome_email(user)
  #   @user = user
  #   @user_name = @user.name
  #   @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
  #   begin
  #     if user.raw_invitation_token.nil?
  #       # Existing user, just need to login
  #       # @login_link += "/users/sign-in"
  #       user = User.find_by(id: user.id) # Reload user to ensure raw_invitation_token is up-to-date
  #       # user.invite!(user.email, skip_invitation: true) if user.raw_invitation_token.nil?
  #       Rails.logger.info "User #{user.id} has raw_invitation_token: #{user.raw_invitation_token}"

  #       @login_link += "/welcome/token/#{user.raw_invitation_token}"
  #     else
  #       # New user, need to use the token
  #       @login_link += "/welcome/token/#{user.raw_invitation_token}"
  #     end
  #     encoded_email = ERB::Util.url_encode(@user.email)
  #     @login_link += "?email=#{encoded_email}"
  #     Rails.logger.info "Sending welcome email to #{@user.email} with login link: #{@login_link}"
  #     subject = "Welcome to SpeakAnyWay AAC!"
  #     mail(to: @user.email, subject: subject)
  #   rescue => e
  #     Rails.logger.error "Error sending welcome email to #{@user.email}: #{e.message}"
  #     Rails.logger.error e.backtrace.join("\n")
  #     raise e
  #   end
  # end

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
    mail(to: @user.email, subject: subject)
  end

  def welcome_new_vendor_email(user, vendor)
    @user = user
    @user_name = @user.name
    @vendor = vendor
    Rails.logger.info "Sending welcome new vendor email to #{@user.email} for vendor #{@vendor.id}"
    @vendor_name = @vendor.business_name
    @menu_url = @vendor.public_url
    @setup_url = @vendor.setup_url
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    if @user.raw_invitation_token.nil?
      @user = User.invite!(email: @user.email, name: @user.name) do |u|
        u.skip_invitation = true
      end

      @login_link += "/welcome/token/#{user.raw_invitation_token}"
    else
      # New user, need to use the token
      @login_link += "/welcome/token/#{user.raw_invitation_token}"
    end
    encoded_email = ERB::Util.url_encode(@user.email)
    @login_link += "?email=#{encoded_email}"
    subject = "Welcome to SpeakAnyWay AAC - #{@vendor_name}!"
    mail(to: @user.email, subject: subject)
  end

  def welcome_to_organization_email(user, organization)
    @user = user
    @user_name = @user.name
    @organization = organization
    @organization_name = @organization.name
    @organization_admin = @organization.admin_user
    @organization_admin_name = @organization_admin.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    if user.raw_invitation_token.nil?
      # Existing user, just need to login
      @login_link += "/users/sign-in"
    else
      # New user, need to use the token
      @login_link += "/welcome/token/#{user.raw_invitation_token}"
    end
    @login_link += "?email=#{user.email}"
    subject = "You have been invited to join #{@organization_name} on SpeakAnyWay AAC!"
    Rails.logger.info "Sending welcome to organization email to #{@user.email} from #{@organization_admin.id}"
    Rails.logger.info "Login link: #{@login_link}"
    mail(to: @user.email, subject: subject)
  end

  def welcome_with_claim_link_email(user, slug)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    if @user.raw_invitation_token.nil?
      # Existing user, just need to login
      @user = User.find(user.id) # Reload user to ensure raw_invitation_token is up-to-date
      user = User.invite!(email: @user.email, name: @user.name) do |u|
        u.skip_invitation = true
      end
      @user = user if user.present?
      Rails.logger.info "Generated new raw_invitation_token for user #{@user.id}: #{@user.raw_invitation_token}"
    else
      Rails.logger.info "User #{@user.id} already has a raw_invitation_token, using it for welcome link"
    end
    token = @user.raw_invitation_token
    Rails.logger.info "User #{@user.id} has raw_invitation_token: #{token}"
    @login_link += "/welcome/token/#{token}"
    @login_link += "?email=#{ERB::Util.url_encode(user.email)}&claim=#{slug}"

    @claim_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @claim_link += "/c/#{slug}"
    @mymyspeak_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @mymyspeak_link += "/my/#{slug}"
    subject = "Welcome to MySpeak - Claim your profile!"
    Rails.logger.info "Sending welcome email to #{@user.email} with claim link"
    mail(to: @user.email, subject: subject)
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
    mail(to: @recipient.email, subject: subject)
  end
end
