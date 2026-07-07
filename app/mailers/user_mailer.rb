class UserMailer < BaseMailer
  default from: "SpeakAnyWay <noreply@speakanyway.com>"

  def welcome_email(user)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.welcome_email.subject"))
    end
  end

  def delete_account_email(user)
    @user = user
    @user_name = @user.name
    @support_email = "support@speakanyway.com"
    @confirmation_link = "#{ENV["FRONT_END_URL"] || "http://localhost:8100"}/delete-account/confirm"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.delete_account_email.subject"))
    end
  end

  def temporary_login_email(user, expiration_hours)
    @user = user
    @user_name = @user.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @expiration_hours = expiration_hours
    Rails.logger.info "Generating temporary login link for user #{user.id} with token #{user.temp_login_token}"
    Rails.logger.info "Front end URL: #{@login_link}"
    @login_link += "/temp-login/#{user.temp_login_token}?email=#{ERB::Util.url_encode(user.email)}"
    Rails.logger.info "Sending temporary login email to #{@user.email} with link: #{@login_link}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.temporary_login_email.subject"))
    end
  end

  def confirm_update_email(user, opts = {})
    user.reload
    @user = user
    @token = @user.confirmation_token
    if @token.nil?
      Rails.logger.error "No confirmation token found for user #{@user.id}"
      return
    end
    @email = @user.unconfirmed_email
    @old_email = @user.email
    @FRONT_END_URL = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @confirmation_url = @FRONT_END_URL + "/confirm-email?confirmation_token=#{@token}"

    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.confirm_update_email.subject"))
    end
  end

  # Plan-neutral "your account is ready" receipt for paid-intent signups
  # (email_signup): the user hasn't reached Stripe checkout yet, so we don't
  # know which plan to welcome them onto. The real plan welcome is sent later
  # from the Stripe webhook (handle_subscription_upsert) once trial/active.
  def welcome_email_receipt(user, raw_invitation_token = nil)
    @user = user
    @user_name = @user.name
    @login_link = welcome_login_link(user, raw_invitation_token)
    Rails.logger.info "Sending welcome receipt email to #{@user.email} with login link: #{@login_link}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.welcome_email_receipt.subject"))
    end
  end

  # raw_invitation_token must be passed explicitly as a String: the virtual
  # attr on @user is always nil here because deliver_later round-trips the
  # User through GlobalID. Without the arg, links fall back to /users/sign-in.
  def welcome_free_email(user, raw_invitation_token = nil)
    @user = user
    @user_name = @user.name
    @login_link = welcome_login_link(user, raw_invitation_token)
    Rails.logger.info "Sending welcome free email to #{@user.email} with login link: #{@login_link}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.welcome_free_email.subject"))
    end
  end

  def welcome_basic_email(user, raw_invitation_token = nil)
    @user = user
    @user_name = @user.name
    @login_link = welcome_login_link(user, raw_invitation_token)
    Rails.logger.info "Sending welcome basic email to #{@user.email} with login link: #{@login_link}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.welcome_basic_email.subject"))
    end
  end

  def welcome_pro_email(user, raw_invitation_token = nil)
    @user = user
    @user_name = @user.name
    @login_link = welcome_login_link(user, raw_invitation_token)
    Rails.logger.info "Sending welcome pro email to #{@user.email} with login link: #{@login_link}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.welcome_pro_email.subject"))
    end
  end

  def welcome_invitation_email(user, inviter_id)
    @user = user
    @user_name = @user.name
    @inviter = User.find(inviter_id&.to_i)
    @inviter_name = @inviter.name
    @login_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @login_link += "/welcome/token/#{user.raw_invitation_token}"
    Rails.logger.info "Sending welcome invitation email to #{user.email} from #{inviter_id}"
    Rails.logger.info "Login link: #{@login_link}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.welcome_invitation_email.subject"))
    end
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
    with_user_locale(@user) do
      mail(
        to: @user.email,
        subject: I18n.t("user_mailer.welcome_new_vendor_email.subject", vendor_name: @vendor_name),
      )
    end
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
    Rails.logger.info "Sending welcome to organization email to #{@user.email} from #{@organization_admin.id}"
    Rails.logger.info "Login link: #{@login_link}"
    with_user_locale(@user) do
      mail(
        to: @user.email,
        subject: I18n.t(
          "user_mailer.welcome_to_organization_email.subject",
          organization_name: @organization_name,
        ),
      )
    end
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
      token = @user.raw_invitation_token
      @login_link += "/welcome/token/#{token}"
      Rails.logger.info "Generated new raw_invitation_token for user #{@user.id}: #{@user.raw_invitation_token}"
    else
      Rails.logger.info "User #{@user.id} already has a raw_invitation_token, using it for welcome link"
      token = @user.raw_invitation_token
      Rails.logger.info "User #{@user.id} has raw_invitation_token: #{token}"
      @login_link += "/welcome/token/#{token}"
    end

    @login_link += "?email=#{ERB::Util.url_encode(user.email)}&claim=#{slug}"

    @claim_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @claim_link += "/c/#{slug}"
    @mymyspeak_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @mymyspeak_link += "/my/#{slug}"
    Rails.logger.info "Sending welcome email to #{@user.email} with claim link"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.welcome_with_claim_link_email.subject"))
    end
  end

  # Confirmation that a paid subscription was canceled (Stripe fired
  # customer.subscription.deleted and the user was downgraded to Free).
  # Explains that boards over the Free limit are now read-only (one board
  # stays editable, auto-pinned by pin_default_editable_board!) and offers a
  # re-subscribe CTA. Not sent to admins.
  def subscription_canceled_email(user)
    @user = user
    @user_name = @user.name
    @plans_link = "#{ENV["FRONT_END_URL"] || "http://localhost:8100"}/pricing"
    @dashboard_link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    Rails.logger.info "Sending subscription canceled email to #{@user.email}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.subscription_canceled_email.subject"))
    end
  end

  # Sent once when a renewal charge fails and the subscription moves
  # active -> past_due. Stripe redelivers invoice.payment_failed on every
  # dunning retry, so the webhook gates this on the status transition — this
  # method only composes the message. Access continues while Stripe retries;
  # if the retries exhaust, the subscription cancels and the user drops to Free.
  def payment_failed_email(user)
    @user = user
    @user_name = @user.name
    @billing_link = "#{ENV["FRONT_END_URL"] || "http://localhost:8100"}/billing"
    Rails.logger.info "Sending payment failed email to #{@user.email}"
    with_user_locale(@user) do
      mail(to: @user.email, subject: I18n.t("user_mailer.payment_failed_email.subject"))
    end
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
    Rails.logger.info "Sending message notification email to #{@recipient.email}"
    with_user_locale(@recipient) do
      mail(
        to: @recipient.email,
        subject: I18n.t("user_mailer.message_notification_email.subject", sender_name: @sender.name),
      )
    end
  end

  private

  def welcome_login_link(user, raw_invitation_token)
    link = ENV["FRONT_END_URL"] || "http://localhost:8100"
    link += raw_invitation_token.present? ? "/welcome/token/#{raw_invitation_token}" : "/users/sign-in"
    link + "?email=#{ERB::Util.url_encode(user.email)}"
  end
end
