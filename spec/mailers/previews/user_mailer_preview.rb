# Preview all emails at http://localhost:3000/rails/mailers/user_mailer
class UserMailerPreview < ActionMailer::Preview
  def welcome_free_email
    @user = User.first
    UserMailer.welcome_free_email(@user)
  end

  def welcome_basic_email
    # @user = User.first
    @user = User.invite!(email: "brittany+basic_user9925x@speakanyway.com", skip_invitation: true)
    puts "Created user with email: #{@user.email}, id: #{@user.id}"
    @user.plan_type = "basic"
    @user.save!
    UserMailer.welcome_basic_email(@user)
  end

  def welcome_pro_email
    @user = User.first
    @user.plan_type = "pro"
    UserMailer.welcome_pro_email(@user)
  end

  def welcome_invitation_email
    @user = User.first
    email = "bhannajohns+new_user@gmail.com"
    new_user = User.invite!(email: email, skip_invitation: true)
    UserMailer.welcome_invitation_email(new_user, @user.id)
  end

  def welcome_new_vendor_email
    vendor = Vendor.first
    return unless vendor && vendor.user
    @user = vendor.user
    email = "bhannajohns+vendor@gmail.com"
    new_user = User.invite!(email: email, skip_invitation: true)
    UserMailer.welcome_new_vendor_email(new_user, vendor)
  end

  def welcome_to_organization_email
    email = "brittany+org-email-test@speakanyway.com"
    @organization_admin = User.where.not(organization_id: nil).first
    if @organization_admin.nil?
      @organization_admin = User.first
      @organization = Organization.create_for_user(@organization_admin, "Test Organization")
    else
      @organization = @organization_admin.organization
    end
    new_user = User.invite!(email: email, skip_invitation: true)
    UserMailer.welcome_to_organization_email(new_user, @organization)
  end

  def welcome_with_claim_link_email
    @user = User.first
    email = "bhannajohns+myspeak9925@gmail.com"
    new_user = User.invite!(email: email, skip_invitation: true)
    new_user.plan_type = "myspeak"
    new_user.save!
    UserMailer.welcome_with_claim_link_email(new_user, "test-claim-link")
  end

  def message_notification_email
    @message = Message.first
    @sender = @message.sender
    @recipient = @message.recipient
    UserMailer.message_notification_email(@message)
  end
end
