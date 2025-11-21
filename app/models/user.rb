# == Schema Information
#
# Table name: users
#
#  id                     :bigint           not null, primary key
#  email                  :string           default(""), not null
#  encrypted_password     :string           default(""), not null
#  reset_password_token   :string
#  reset_password_sent_at :datetime
#  remember_created_at    :datetime
#  sign_in_count          :integer          default(0), not null
#  current_sign_in_at     :datetime
#  last_sign_in_at        :datetime
#  current_sign_in_ip     :string
#  last_sign_in_ip        :string
#  name                   :string
#  role                   :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  tokens                 :integer          default(0)
#  stripe_customer_id     :string
#  authentication_token   :string
#  jti                    :string           not null
#  invitation_token       :string
#  invitation_created_at  :datetime
#  invitation_sent_at     :datetime
#  invitation_accepted_at :datetime
#  invitation_limit       :integer
#  invited_by_id          :integer
#  invited_by_type        :string
#  current_team_id        :bigint
#  play_demo              :boolean          default(TRUE)
#  settings               :jsonb
#  base_words             :string           default([]), is an Array
#  plan_type              :string           default("free")
#  plan_expires_at        :datetime
#  plan_status            :string           default("active")
#  monthly_price          :decimal(8, 2)    default(0.0)
#  yearly_price           :decimal(8, 2)    default(0.0)
#  total_plan_cost        :decimal(8, 2)    default(0.0)
#  uuid                   :uuid
#  child_lookup_key       :string
#  locked                 :boolean          default(FALSE)
#  organization_id        :bigint
#  vendor_id              :bigint
#
require "csv"

class User < ApplicationRecord
  # Payment and authentication setup
  pay_customer default_payment_processor: :stripe
  include Devise::JWT::RevocationStrategies::JTIMatcher
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :invitable, :trackable,
         :jwt_authenticatable, jwt_revocation_strategy: self

  # Associations
  belongs_to :organization, optional: true
  has_many :boards, -> { where(is_template: false) }, class_name: "Board", dependent: :destroy
  has_many :template_boards, -> { where(is_template: true) }, class_name: "Board", dependent: :destroy
  has_many :board_images, through: :boards
  has_many :board_groups, dependent: :destroy
  has_many :menus, dependent: :destroy
  has_many :images, dependent: :destroy
  has_many :docs, dependent: :destroy
  has_many :user_docs, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :openai_prompts, dependent: :destroy
  has_many :team_users, dependent: :destroy
  belongs_to :current_team, class_name: "Team", optional: true
  has_many :word_events, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_secure_token :authentication_token
  has_many :child_accounts, dependent: :destroy
  has_many :scenarios, dependent: :destroy
  has_many :created_teams, class_name: "Team", foreign_key: "created_by_id", dependent: :destroy
  has_one :profile, as: :profileable, dependent: :destroy
  belongs_to :vendor, optional: true
  has_many :board_screenshot_imports, dependent: :destroy

  # has_many :sent_messages, class_name: "Message", foreign_key: "sender_id", dependent: :destroy
  # has_many :received_messages, class_name: "Message", foreign_key: "recipient_id", dependent: :destroy

  # Scopes
  scope :admin, -> { where(role: "admin") }
  scope :pro, -> { where(plan_type: "pro") }
  scope :free, -> { where(plan_type: "free") }
  scope :basic, -> { where(plan_type: "basic") }
  scope :plus, -> { where(plan_type: "plus") }
  scope :vendor, -> { where(role: "vendor") }
  scope :partner, -> { where(role: "partner") }

  scope :non_admin, -> { where.not(role: "admin") }
  scope :with_artifacts, -> { includes(user_docs: { doc: { image_attachment: :blob } }, docs: { image_attachment: :blob }) }

  include WordEventsHelper
  include API::WebhooksHelper
  # Constants
  # DEFAULT_ADMIN_ID = self.admin.first&.id
  DEFAULT_ADMIN_ID = Rails.env.development? ? 2 : 1

  # Callbacks
  before_save :set_default_settings, unless: :settings?
  after_create :add_welcome_tokens
  # after_create :create_opening_board
  before_validation :set_uuid, on: :create
  before_save :ensure_settings, unless: :has_all_settings?

  before_destroy :delete_stripe_customer
  before_destroy :unassign_vendor

  def set_uuid
    return if self.uuid.present?
    self.uuid = SecureRandom.uuid
  end

  def locked?
    locked == true
  end

  def timezone
    self.settings["timezone"] || "America/New_York"
  end

  def self.clear_all_custom_default_boards
    self.all.each do |user|
      user.clear_custom_default_board
    end
  end

  def self.reset_user_limits
    self.non_admin.each do |user|
      user.settings ||= {}
      user.settings["extra_communicators"] = 0
      user.settings["total_communicators"] = user.settings["communicator_limit"] || 0
      comm_account_limit = API::WebhooksHelper.get_communicator_limit(user.plan_type || "free")

      board_limit = API::WebhooksHelper.get_board_limit(comm_account_limit, user.role || "user")
      if user.plan_type == "free" || user.plan_type == "myspeak"
        board_limit = 1
      end
      user.settings["board_limit"] = board_limit
      user.settings["communicator_limit"] = comm_account_limit
      puts "Resetting limits for user #{user.email} (#{user.plan_type}): communicator_limit=#{comm_account_limit}, board_limit=#{board_limit}"
      user.save
    end
  end

  def messages
    Message.where("sender_id = ? OR recipient_id = ?", id, id)
  end

  def sent_messages
    Message.where(sender_id: id, sender_deleted_at: nil)
  end

  def received_messages
    Message.where(recipient_id: id, recipient_deleted_at: nil)
  end

  def has_available_communicator?
    true # TODO: Implement logic to check if the user has available communicators
  end

  def self.create_from_email(email, stripe_customer_id = nil, inviting_user_id = nil, slug = nil)
    begin
      user = User.find_by(email: email)
      user = User.invite!(email: email, skip_invitation: true) unless user
    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.error("Error creating user from email: #{email} - #{e.message}")

      user = User.find_by(stripe_customer_id: stripe_customer_id) if stripe_customer_id
      if user.nil?
        user = User.find_by(email: email)
      end
    rescue => e
      Rails.logger.error("Unexpected error creating user from email: #{email} - #{e.message}")
    end
    Rails.logger.error("FAILED while creating user from email: #{email}, inviting_user_id: #{inviting_user_id}, slug: #{slug}, stripe_customer_id: #{stripe_customer_id} errors: #{user.errors.full_messages.join(", ")}") if user && user.errors.any?
    user.ensure_settings
    user.role = "user" unless user.role
    user.plan_type ||= "free"
    user.plan_status ||= "active"
    user.settings ||= {}
    user.settings["plan_nickname"] = user.plan_type
    user.settings["slug"] = slug if slug

    if user
      if inviting_user_id
        Rails.logger.info("Creating user from invitation with inviting_user_id: #{inviting_user_id}")
        create_from_invitation(email, inviting_user_id)
      else
        user.send_welcome_email if user.should_send_welcome_email?
        stripe_customer_id ||= user.stripe_customer_id
        if stripe_customer_id.nil?
          stripe_customer_id = User.create_stripe_customer(email)
        end
        user.stripe_customer_id = stripe_customer_id
        user.save
      end
    else
      Rails.logger.error("User not created: #{email}")
    end
    user
  end

  def self.create_from_invitation(email, invited_by_id)
    user = User.invite!(email: email, skip_invitation: true)
    if user
      user.invited_by_id = invited_by_id
      user.invited_by_type = "User"
      user.send_welcome_invitation_email(invited_by_id)
      user.save
      stripe_customer_id = User.create_stripe_customer(email)
      user.stripe_customer_id = stripe_customer_id
      user.save
      Rails.logger.info("User created from invitation: #{email}")
    else
      Rails.logger.error("User not created from invitation: #{email}")
    end
    user
  end

  def self.create_new_vendor_user(email, vendor, stripe_customer_id, plan_nickname)
    if email.blank? || stripe_customer_id.blank?
      Rails.logger.error("Invalid parameters for creating new vendor user: email: #{email}, business_name: #{business_name}, stripe_customer_id: #{stripe_customer_id}")
      return nil
    end
    business_name = vendor.business_name
    user = User.find_by(email: email)
    found_user = user
    user = User.invite!(email: email, skip_invitation: true) unless user
    Rails.logger.info("found_user: #{found_user} --Creating new vendor user with email: #{email}, business_name: #{business_name}, stripe_customer_id: #{stripe_customer_id}")
    if user && !found_user
      user.plan_type = plan_nickname
      user.settings ||= {}
      user.settings["plan_nickname"] = plan_nickname
      user.plan_status = "active"
      user.stripe_customer_id = stripe_customer_id
      user.role = "vendor"
      user.vendor = vendor
      user.save!
      Rails.logger.info("#{business_name} - New vendor user created: #{user.email}")

      # user.send_welcome_new_vendor(vendor) if vendor

      Rails.logger.info("New vendor user created: #{email}")
    elsif found_user
      Rails.logger.info("Found existing user for vendor: #{email}")
      if found_user.raw_invitation_token
        Rails.logger.info("User already has an invitation token: #{found_user.raw_invitation_token}")
      else
        Rails.logger.info("User does not have an invitation token, generating a new one")
        found_user.skip_invitation = true
        found_user.invite!
        token = found_user.raw_invitation_token
        Rails.logger.info("Generated new invitation token: #{token} for user: #{email}")
      end
      found_user.send_welcome_new_vendor(vendor) if vendor

      user = found_user
      user.role = "vendor"
      user.vendor = vendor
      user.save!
    else
      Rails.logger.error("User not created for vendor: #{email}")
      return nil
    end
    user
  end

  def self.non_admin_users
    where.not(role: "admin")
  end

  def recently_used_boards
    recent_word_events = word_events.where("created_at >= ?", 1.week.ago)
    board_ids = recent_word_events.pluck(:board_id).uniq
    boards.where(id: board_ids).limit(10)
  end

  def board_limit
    settings["board_limit"] || 1
  end

  def comm_account_limit
    settings["communicator_limit"] || 1
  end

  def update_from_stripe_event(data_object, plan_nickname)
    plan_nickname = plan_nickname || "free"
    Rails.logger.info "Updating user from Stripe event with plan: #{plan_nickname}"

    if data_object["customer"]
      self.stripe_customer_id = data_object["customer"]
    end
    self.settings ||= {}

    if new_user?
      plan_type = API::WebhooksHelper.get_plan_type(plan_nickname)
      self.plan_type = plan_type
      user_role = API::WebhooksHelper.get_user_role(plan_type)

      initial_comm_account_limit = API::WebhooksHelper.get_communicator_limit(plan_type)
      initial_board_limit = API::WebhooksHelper.get_board_limit(initial_comm_account_limit, user_role)
      self.role = user_role if user_role && !self.admin?

      self.settings["communicator_limit"] = initial_comm_account_limit if initial_comm_account_limit && !self.settings["communicator_limit"]
      self.settings["plan_nickname"] = plan_nickname
      extra_communicators = settings["extra_communicators"] || 0
      self.settings["extra_communicators"] = extra_communicators
      total_communicators = initial_comm_account_limit + extra_communicators
      self.settings["total_communicators"] = total_communicators
      if plan_type == "free" || plan_type == "myspeak"
        # For free plan, set a default board limit
        initial_board_limit = 1
        if plan_type == "free"
          self.settings["communicator_limit"] = 0
        else
          self.settings["communicator_limit"] = 1
        end
      end
      self.settings["board_limit"] = initial_board_limit
      Rails.logger.info "Initial board limit set to: #{initial_board_limit}"
    end
    if data_object["cancel_at_period_end"]
      Rails.logger.info "Canceling at period end"
      self.plan_status = "pending cancelation"
      self.settings["cancel_at"] = Time.at(data_object["cancel_at"])
      self.settings["cancel_at_period_end"] = data_object["cancel_at_period_end"]
    else
      self.plan_status = data_object["status"]
    end
    is_free_access = plan_nickname.split("_").last == "free"
    if is_free_access
      self.settings["free_access"] = true
    end
    expires_at = data_object["current_period_end"] || data_object["expires_at"]
    self.plan_expires_at = Time.at(expires_at) if expires_at
    self.save!
    Rails.logger.info "User updated from Stripe event: #{self.email}, plan type: #{self.plan_type}, plan_expires_at: #{self.plan_expires_at}"

    return true
  end

  def get_stripe_subscriptions
    begin
      subscriptions = Stripe::Subscription.list({ customer: stripe_customer_id })
      subscriptions.each do |subscription|
        puts "Subscription ID: #{subscription.inspect}"
        puts "-----------------------------"
      end
    rescue Stripe::StripeError => e
      Rails.logger.error "Error retrieving subscriptions: #{e.message}"
    end
    subscriptions
  end

  def self.handle_new_partner_pro_subscription(user, plan_nickname = "partner_pro")
    Rails.logger.info "Handling Partner Pro subscription for user: #{user.email} with plan_nickname: #{plan_nickname}"
    user.role = "partner"
    user.plan_status = "active"
    user.plan_expires_at = Time.now + 3.months if user.plan_expires_at.nil?
    partner_group = user.get_partner_group
    user.settings["partner_group"] = partner_group
    user.save!
    begin
      MailchimpService.new.update_subscriber_tags(user.email, [partner_group], [])
    rescue => e
      Rails.logger.error "Mailchimp tag update failed for pilot_partner: #{e.message}"
    end
  rescue StandardError => e
    Rails.logger.error "Error handling Partner Pro subscription for user #{user&.email}: #{e.inspect}"
  end

  def opening_board
    Board.find_by(id: settings["opening_board_id"]&.to_i)
  end

  def self.without_opening_board
    self.where("settings->>'opening_board_id' IS NULL")
  end

  def self.fix_user_opening_boards
    self.non_admin.each do |user|
      user.fix_user_opening_board
    end
  end

  def fix_user_opening_board
    new_opening_board = nil
    if opening_board.nil?
      new_opening_board = create_opening_board
    else
      if opening_board.images.count < 10
        opening_board.destroy
        new_opening_board = create_opening_board
      end
    end
    new_opening_board
  end

  def unassign_vendor
    return unless vendor_id
    Rails.logger.info "Unassigning vendor for user #{id} with vendor_id #{vendor_id}"
    vendor = Vendor.find_by(user_id: id, id: vendor_id)
    if vendor
      Rails.logger.info "Found vendor #{vendor.business_name} for user #{id}, unassigning..."
      vendor.user_id = nil
      vendor.save
      self.vendor_id = nil
      self.save
    else
      Rails.logger.warn "No vendor found for user #{id} with vendor_id #{vendor_id}"
    end
  end

  def delete_stripe_customer
    return unless stripe_customer_id
    return if Rails.env.production? && !ENV["STRIPE_DELETE_CUSTOMERS"]
    begin
      result = Stripe::Customer.delete(stripe_customer_id)
    rescue StandardError => e
      Rails.logger.error "Error deleting Stripe customer: #{e.message}"
      return
    end
    Rails.logger.info "Deleted stripe customer: #{result}" if result["deleted"]
  end

  def self.create_stripe_customer(email)
    result = Stripe::Customer.create({ email: email })
    free_plan_id = ENV["STRIPE_FREE_PLAN_ID"] || "price_1QrmMGGfsUBE8bl39Anm4Pyg"
    Stripe::Subscription.create({
      customer: result["id"],
      items: [{ price: free_plan_id }],
    })
    Rails.logger.info "Created stripe customer: #{result}"
    result["id"]
  end

  def all_required_settings
    %w[wait_to_speak disable_audit_logging enable_image_display enable_text_display show_labels show_tutorial]
  end

  def false_settings
    %w[wait_to_speak disable_audit_logging]
  end

  def true_settings
    %w[enable_image_display enable_text_display show_labels show_tutorial]
  end

  def has_all_settings?
    all_required_settings.all? { |setting| settings[setting] }
  end

  def ensure_settings
    self.settings = {} unless settings
    all_required_settings.each do |setting|
      settings[setting] = false if false_settings.include?(setting) && settings[setting].nil?
      settings[setting] = true if true_settings.include?(setting) && settings[setting].nil?
    end
    settings
  end

  def create_opening_board
    Board.create_dynamic_default_for_user(self)
  end

  # Methods for user settings
  def set_default_settings
    default_settings = ensure_settings
    voice_settings = { name: "alloy", speed: 1.0, pitch: 1.0, volume: 1.0, rate: 1.0, language: "en-US" }
    default_settings["voice"] = voice_settings unless settings["voice"]
    # self.settings = { voice: voice_settings, wait_to_speak: false, disable_audit_logging: false,
    #                   enable_image_display: true, enable_text_display: true, show_labels: true, show_tutorial: true }
    self.settings = default_settings
    save
  end

  def predictive_boards
    boards.predictive.includes(:parent, :board_images).order(name: :asc)
  end

  def predictive_board_id
    settings["predictive_board_id"]
  end

  def dynamic_boards
    boards.dynamic.includes(:parent, :board_images).order(name: :asc)
  end

  def predictive_images
    images.joins(:board_images).where(board_images: { board_id: predictive_boards.select(:id) }).distinct
  end

  def add_to_settings(key, value)
    settings[key] = value
    save
  end

  # Methods for handling teams and boards
  def team_boards
    TeamBoard.where(team_id: team_users.select(:team_id))
  end

  def current_team_boards
    TeamBoard.where(team_id: current_team_id)
  end

  def teams
    Team.where(id: team_users.select(:team_id))
  end

  def shared_with_me_boards
    Board.with_artifacts.where(id: team_boards.select(:board_id))
  end

  # Token management
  def add_welcome_tokens
    add_tokens(10)
  end

  def add_tokens(amount)
    update(tokens: tokens + amount)
  end

  def remove_tokens(amount)
    update(tokens: tokens - amount)
  end

  # Authorization and access control methods
  def admin?
    role == "admin"
  end

  def demo?
    play_demo == true
  end

  def can_edit?(model)
    return false unless model
    return true if admin?
    return false if model.respond_to?(:predefined) && model.predefined
    model&.user_id == id
  end

  def can_view_account?(account_id)
    return false unless account_id
    account = ChildAccount.find_by(id: account_id)
    return false unless account
    return true if account.user_id == id
    return true if admin?
    account_teams = account.teams
    return true if account.team_users.where(user_id: id, role: "admin").exists?
    return true if account.team_users.where(user_id: id, role: "member").exists?
    return true if account.team_users.where(user_id: id, role: "supporter").exists?
    return false if account.team_users.where(user_id: id, role: "restricted").exists?
    false
  end

  def can_edit_profile?(profile_id)
    return false unless profile_id
    account_profile = Profile.find_by(id: profile_id.to_i)
    return false unless account_profile

    if account_profile.user_id == id
      return true
    end
    return true if admin?
    comm_account = ChildAccount.find_by(id: account_profile.profileable_id)
    teams = comm_account.teams if comm_account
    if teams && teams.any? { |team| team.team_users.where(user_id: id, role: "admin").exists? }
      return true
    end
    false
  end

  def can_add_boards_to_account?(account_ids)
    return false unless account_ids
    account_id = account_ids.first

    account = ChildAccount.includes(teams: :team_users).find_by(id: account_id)
    return false unless account
    return true if account.user_id == id
    return true if admin?
    account_teams = account.teams
    return true if account.team_users.where(user_id: id, role: "admin").exists?
    return true if account.team_users.where(user_id: id, role: "member").exists?
    return true if account.team_users.where(user_id: id, role: "supporter").exists?
    return false if account.team_users.where(user_id: id, role: "restricted").exists?
    false
  end

  def can_favorite?(model)
    return false unless model
    return true if admin? || !model.user_id || model.user_id == DEFAULT_ADMIN_ID
    model&.user_id == id
  end

  # Document-related methods
  def favorite_docs
    Doc.with_attached_image.joins(:user_docs).where(user_docs: { user_id: id })
  end

  def display_docs_for_image(image_id)
    ActiveRecord::Base.logger.silence do
      docs = Doc.joins(:user_docs)
        .where(user_docs: { user_id: id, image_id: image_id })
        .all
      return docs if docs.present?
      Doc.joins(:user_docs)
         .where(user_docs: { user_id: [nil, DEFAULT_ADMIN_ID], image_id: image_id })
         .all
    end
  end

  def voice_settings
    settings["voice"] = { name: "alloy", speed: 1, pitch: 1, volume: 1, rate: 1, language: "en-US" } unless settings["voice"]
    settings["voice"]
  end

  def voice
    voice_settings["name"]
  end

  def language
    voice_settings["language"] || "en-US"
  end

  def is_a_favorite?(doc)
    favorite_docs.include?(doc)
  end

  # Helper methods
  def display_name
    name.blank? ? email : name
  end

  def first_name
    return email.split("@").first if name.blank?
    name.split(" ").first
  end

  def last_name
    return "" if name.blank?
    name.split(" ").last
  end

  def self.default_admin
    admin.find(DEFAULT_ADMIN_ID)
  end

  def self.valid_credentials?(email, password)
    user = find_by(email: email)
    user&.valid_password?(password) ? user : nil
  end

  def invite_to_team!(team, inviter)
    BaseMailer.team_invitation_email(self.email, inviter, team).deliver_now
  end

  def invite_new_user_to_team!(new_user_email, team)
    new_user = User.invite!({ email: new_user_email }, self)
    if new_user.errors.any?
      Rails.logger.error "Errors: #{new_user.errors.full_messages}"
      raise "User not created: #{new_user.errors.full_messages}"
    end
    # BaseMailer.team_invitation_email(new_user_email, self, team).deliver_now
    BaseMailer.team_invitation_email(new_user.email, self, team).deliver_now

    stripe_customer_id = User.create_stripe_customer(new_user_email)
    new_user.update!(stripe_customer_id: stripe_customer_id)

    new_user
  end

  def send_welcome_email_free
    Rails.logger.info "Sending free welcome email to #{email}"
    UserMailer.welcome_free_email(self).deliver_now
  end

  def send_welcome_email_basic
    Rails.logger.info "Sending paid welcome email to #{email}"
    UserMailer.welcome_basic_email(self).deliver_now
  end

  def send_welcome_email_pro
    Rails.logger.info "Sending paid welcome email to #{email}"
    UserMailer.welcome_pro_email(self).deliver_now
  end

  def send_welcome_email_myspeak(slug)
    Rails.logger.info "Sending myspeak welcome email to #{email} with slug #{slug}"
    slug ||= settings["slug"] || email.split("@").first
    UserMailer.welcome_with_claim_link_email(self, slug).deliver_now
  end

  def send_welcome_email(plan_nickname = nil, slug = nil)
    unless plan_nickname
      plan_nickname = settings["plan_nickname"] || plan_type
    end
    begin
      if plan_nickname.nil? || plan_nickname.include?("free")
        send_welcome_email_free
      elsif plan_nickname.include?("basic")
        send_welcome_email_basic
      elsif plan_nickname.include?("pro") || plan_nickname.include?("plus")
        send_welcome_email_pro
      elsif plan_nickname.include?("myspeak")
        if slug.nil?
          slug = settings["slug"] || email.split("@").first
        end
        send_welcome_email_myspeak(slug)
      else
        Rails.logger.error "Unknown plan nickname: #{plan_nickname}, sending free welcome email"
        send_welcome_email_free
      end
      self.settings["welcome_email_sent"] = true
      self.save
      AdminMailer.new_user_email(self).deliver_now
      update_mailchimp_subscription

      Rails.logger.info "Welcome email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending welcome email: #{e.message}")
    end
  end

  def send_pro_setup_email
    Rails.logger.info "Sending pro setup email to #{email}"
    begin
      SetupMailer.pro_setup_email(self).deliver_now
      Rails.logger.info "Pro setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending pro setup email: #{e.message}")
    end
  end

  def send_free_setup_email
    Rails.logger.info "Sending free setup email to #{email}"
    begin
      SetupMailer.free_setup_email(self).deliver_now
      Rails.logger.info "Free setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending free setup email: #{e.message}")
    end
  end

  def send_vendor_setup_email
    Rails.logger.info "Sending vendor setup email to #{email}"
    begin
      SetupMailer.vendor_setup_email(self).deliver_now
      Rails.logger.info "Vendor setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending vendor setup email: #{e.message}")
    end
  end

  def send_myspeak_setup_email
    Rails.logger.info "Sending myspeak setup email to #{email}"
    begin
      SetupMailer.myspeak_setup_email(self).deliver_now
      Rails.logger.info "Myspeak setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending myspeak setup email: #{e.message}")
    end
  end

  def send_setup_email
    Rails.logger.info "Sending setup email to #{email}"
    begin
      if vendor?
        send_vendor_setup_email
      elsif myspeak?
        send_myspeak_setup_email
      elsif pro? || plus? || premium?
        send_pro_setup_email
      elsif free?
        send_free_setup_email
      end
      Rails.logger.info "Setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending setup email: #{e.message}")
    end
  end

  def send_welcome_invitation_email(inviter_id)
    Rails.logger.info "Sending welcome invitation email to #{email} from user ID #{inviter_id}"
    begin
      UserMailer.welcome_invitation_email(self, inviter_id).deliver_now
      # AdminMailer.new_user_email(self).deliver_now
    rescue => e
      Rails.logger.error("Error sending welcome invitation email: #{e.message}")
    end
  end

  def send_welcome_new_vendor(vendor)
    business_name = vendor.business_name
    Rails.logger.info "Sending welcome new vendor email to #{email} for business #{business_name}"
    begin
      UserMailer.welcome_new_vendor_email(self, vendor).deliver_now
    rescue => e
      Rails.logger.error("Error sending welcome new vendor email: #{e.message}")
    end
  end

  def send_welcome_to_organization_email(inviter_id)
    Rails.logger.info "Sending welcome to organization email to #{email} from user ID #{inviter_id}"
    begin
      UserMailer.welcome_to_organization_email(self, inviter_id).deliver_now
    rescue => e
      Rails.logger.error("Error sending welcome to organization email: #{e.message}")
    end
  end

  def send_welcome_with_claim_link_email(slug)
    Rails.logger.info "Sending welcome with claim link email to #{email} with slug #{slug}"
    begin
      UserMailer.welcome_with_claim_link_email(self, slug).deliver_now
    rescue => e
      Rails.logger.error("Error sending welcome with claim link email: #{e.message}")
    end
  end

  def update_mailchimp_subscription(opts = {})
    MailchimpUpsertSubscriberJob.perform_async(self.id, opts)
  end

  def update_mailchimp_tags
    tags = []
    tags << "#{plan_type&.camelcase(:upper)}Plan" || "FreePlan"
    unless role.blank? || role == "user"
      role_tag = role.capitalize
      tags << role_tag
    end

    plan_status = self.plan_status || "active"
    tags << plan_status.capitalize

    if partner_pro?
      partner_group = get_partner_group
      tags << partner_group
    end
    puts "Updating Mailchimp tags for user #{email}: #{tags.inspect}"
    MailchimpService.new.update_subscriber_tags(email, tags, [])
  rescue => e
    Rails.logger.error "Mailchimp tag update failed: #{e.message}"
  end

  def demo_user?
    email.include?("bhannajohns+") || email.include?("@speakanyway.com")
  end

  def subscription_expired?
    plan_expires_at && plan_expires_at < Time.now
  end

  def partner_pro?
    pro? && role == "partner"
  end

  def get_partner_group
    current_month = Time.now.month
    current_month_name = Date::ABBR_MONTHNAMES[current_month]
    "PartnerPro_#{current_month_name}"
  rescue StandardError => e
    Rails.logger.error "Error determining partner group: #{e.inspect}"
    "PartnerPro_Unknown"
  end

  def record_signin_event
    mailchimp = MailchimpService.new
    mailchimp.record_signin_event(self)
  end

  def should_receive_notifications?
    return false if admin?
    return false if locked?
    return false if settings["disable_notifications"] == true
    return false if settings["disable_notifications"] == "true"
    return false if settings["disable_notifications"] == "1"
    return false if settings["disable_notifications"] == 1
    recently_notified = settings["recently_notified"]
    return false if recently_notified && recently_notified > 2.hours.ago
    true
  end

  def set_recently_notified!
    settings["recently_notified"] = Time.now
    save!
  end

  def resource_type
    "User"
  end

  def pro?
    plan_type == "pro" && role != "vendor"
  end

  def pro_vendor?
    plan_type.include?("pro") && role == "vendor"
  end

  def free?
    plan_type.include? "free"
  end

  def myspeak?
    plan_type.include? "myspeak"
  end

  def basic?
    plan_type.include? "basic"
  end

  def plus?
    plan_type.include? "plus"
  end

  def paid_plan?
    basic? || pro? || plus? || premium? || admin? || myspeak? || pro_vendor?
  end

  def professional?
    pro? || plus? || premium?
  end

  def premium?
    plan_type.include? "premium"
  end

  def to_s
    display_name
  end

  PRO_LIMITS = {
    "ai_image_generation" => 50,
    "ai_image_edit" => 50,
    "ai_suggestions" => 100,
    "ai_scenario" => 30,
    "ai_format_board" => 50,
    "ai_menu_generation" => 20,
  }.freeze

  BASIC_LIMITS = {
    "ai_image_generation" => 10,
    "ai_image_edit" => 10,
    "ai_suggestions" => 20,
    "ai_scenario" => 5,
    "ai_format_board" => 10,
    "ai_menu_generation" => 5,
  }.freeze

  FREE_LIMITS = {
    "ai_image_generation" => 1,
    "ai_image_edit" => 1,
    "ai_suggestions" => 5,
    "ai_scenario" => 1,
    "ai_format_board" => 1,
    "ai_menu_generation" => 1,
  }.freeze

  def daily_limit_for(feature_key)
    if admin?
      return 10000
    end
    if pro? || plus? || premium? || pro_vendor?
      return PRO_LIMITS[feature_key] || 20
    elsif basic?
      return BASIC_LIMITS[feature_key] || 10
    else
      return FREE_LIMITS[feature_key] || 1
    end
  end

  def should_send_welcome_email?
    Rails.logger.info "Checking if welcome email should be sent to #{email} - created at: #{created_at}, plan type: #{plan_type}, admin: #{admin?}"
    return false if admin?
    if settings["welcome_email_sent"] == true
      Rails.logger.info "Welcome email already sent to #{email}"
      return false
    end
    if plan_type == "myspeak"
      Rails.logger.info "Skipping welcome email for myspeak user #{email}"
      return false
    end
    true
  end

  def new_user?
    return false if admin?
    return false if created_at < 1.hour.ago
    true
  end

  TRAIL_PERIOD = 8.days

  def free_trial?
    free? && created_at > TRAIL_PERIOD.ago
  end

  def trial_expired?
    free? && !free_trial?
  end

  def trial_expired_at
    return plan_expires_at if plan_expires_at
    created_at + TRAIL_PERIOD
  end

  def trial_days_left
    (trial_expired_at - Time.now).to_i / 1.day
  end

  def startup_board_group
    startup_board_group_id = settings["startup_board_group_id"]
    board_group = BoardGroup.includes(board_group_boards: :board).find_by(id: startup_board_group_id) if startup_board_group_id
    return board_group if board_group
    BoardGroup.startup
  end

  include ActionView::Helpers::DateHelper

  def admin_index_view
    view = as_json
    view["board_count"] = boards.count
    view["stripe_customer_id"] = stripe_customer_id
    view["trial_days_left"] = trial_days_left
    view["last_sign_in_at"] = time_ago_in_words(last_sign_in_at) if last_sign_in_at
    view["last_sign_in_ip"] = last_sign_in_ip
    view["current_sign_in_at"] = current_sign_in_at
    view["current_sign_in_ip"] = current_sign_in_ip
    view["sign_in_count"] = sign_in_count
    view["plan_type"] = plan_type
    view["plan_expires_at"] = plan_expires_at.strftime("%x") if plan_expires_at
    view["free_trial"] = free_trial?
    view["trial_expired"] = trial_expired?
    view["free"] = free?
    view
  end

  def admin_api_view
    view = as_json
    comm_account_limit_reached = settings["communicator_limit"].to_i + settings["extra_communicators"].to_i <= communicator_accounts.count
    board_limit = settings["board_limit"]
    board_limit = board_limit.to_i if board_limit
    board_limit = 1 unless board_limit && board_limit > 0
    board_count = boards.count
    Rails.logger.info "User #{id} - Board limit: #{board_limit}, Board count: #{board_count}"
    can_create_boards = board_limit > board_count
    board_limit_reached = board_count >= board_limit
    view["admin"] = admin?
    view["free"] = free?
    view["pro"] = pro?
    view["basic"] = basic?
    view["pro_vendor"] = pro_vendor?
    view["plan_type"] = plan_type
    view["plan_expires_at"] = plan_expires_at.strftime("%x") if plan_expires_at
    view["premium"] = premium?
    view["team"] = current_team
    view["free_trial"] = free_trial?
    view["trial_expired"] = trial_expired?
    view["trial_days_left"] = trial_days_left
    view["last_sign_in_at"] = last_sign_in_at
    view["last_sign_in_ip"] = last_sign_in_ip
    view["current_sign_in_at"] = current_sign_in_at
    view["current_sign_in_ip"] = current_sign_in_ip
    view["sign_in_count"] = sign_in_count
    view["tokens"] = tokens
    view["phrase_board_id"] = settings["phrase_board_id"]
    view["opening_board_id"] = settings["opening_board_id"]
    view["has_dynamic_default"] = opening_board.present?
    view["startup_board_group_id"] = settings["startup_board_group_id"]
    view["child_accounts"] = child_accounts.map(&:api_view)
    view["boards"] = boards.distinct.order(name: :asc).map(&:user_api_view)
    view["scenarios"] = scenarios.map(&:api_view)
    view["images"] = images.order(:created_at).limit(10).map { |image| { id: image.id, name: image.name, src: image.src_url } }
    view["display_name"] = display_name
    view["stripe_customer_id"] = stripe_customer_id
    view["board_limit"] = board_limit
    view["comm_account_limit_reached"] = comm_account_limit_reached
    view["board_limit_reached"] = board_limit_reached
    view["can_create_boards"] = can_create_boards
    view["settings"] = settings
    view["settings"]["plan_type"] = plan_type
    view["partner_pro"] = partner_pro?
    view
  end

  def teams_with_read_access
    teams = Team.where(id: team_users.select(:team_id)).where.not(created_by_id: id)
    # team_users.where(role: ["supporter", "member"]).includes(:team).map(&:team).uniq
  end

  def accounts_with_read_access
    teams_with_read_access.map(&:accounts).flatten
  end

  def communicator_accounts
    child_accounts.order(:name).map(&:api_view)
  end

  def favorite_boards
    boards.where(favorite: true).order(name: :asc)
  end

  def go_to_boards
    favorite_boards.any? ? favorite_boards : boards.alphabetical.limit(10)
  end

  def vendor?
    role == "vendor"
  end

  def vendor_account
    return nil unless vendor?
    ChildAccount.find_by(user_id: id, vendor_id: vendor_id) if vendor_id
  end

  def vendor_profile
    return nil unless vendor?
    vendor_account&.profile
  end

  def can_use_ai?
    pro? || plus? || premium? || vendor? || basic?
  end

  def can_create_boards
    board_limit = settings["board_limit"] || 1
    self.boards.reload
    board_count = boards.count
    board_count < board_limit
  end

  def api_view
    plan_exp = plan_expires_at&.strftime("%x")
    comm_limit = settings["communicator_limit"] || 0
    extra_comms = settings["extra_communicators"] || 0
    board_limit = settings["board_limit"] || 1
    go_words = settings["go_to_words"] || Board.common_words

    comm_limit = comm_limit.to_i
    extra_comms = extra_comms.to_i

    memoized_teams = teams_with_read_access
    memoized_communicators = communicator_accounts
    memoized_boards = boards.alphabetical
    board_count = memoized_boards.count
    comm_account_limit_reached = comm_limit + extra_comms <= memoized_communicators.count

    {
      id: id,
      organization_id: organization_id,
      profile: profile&.api_view,
      vendor_profile: vendor_profile&.api_view,
      # vendor: vendor&.api_view,
      is_vendor: vendor?,
      board_limit: board_limit,
      comm_account_limit_reached: comm_account_limit_reached,
      board_limit_reached: board_count >= board_limit,
      can_create_boards: can_create_boards,
      board_count: board_count,
      can_use_ai: can_use_ai?,
      email: email,
      pro_vendor: pro_vendor?,
      role: role,
      name: name,
      display_name: display_name,
      admin: admin?,
      free: free?,
      pro: pro?,
      basic: basic?,
      plus: plus?,
      premium: premium?,
      paid_plan: paid_plan?,
      pro_vendor: vendor?,
      myspeak: myspeak?,
      professional: professional?,
      basic_vendor: vendor? && basic?,
      plan_type: plan_type,
      plan_expires_at: plan_exp,
      free_trial: free_trial?,
      trial_expired: trial_expired?,
      trial_days_left: trial_days_left,
      accounts_included: comm_limit,
      extra_communicators: extra_comms,
      comm_account_limit: comm_limit + extra_comms,
      supervisor_limit: settings["supervisor_limit"] || 0,
      phrase_board_id: settings["phrase_board_id"],
      opening_board_id: settings["opening_board_id"],
      has_dynamic_default: opening_board.present?,
      startup_board_group_id: settings["startup_board_group_id"],
      current_team: current_team,
      teams_with_read_access: memoized_teams.map(&:index_api_view),
      communicator_accounts: memoized_communicators,
      go_to_words: go_words,
      go_to_boards: go_to_boards.map { |b| { id: b.id, name: b.name, display_image_url: b.display_image_url, slug: b.slug, ionic_icon: b.ionic_icon } },
      boards: memoized_boards.map { |b| { id: b.id, name: b.name, word_sample: b.word_sample, frozen: b.is_frozen? } },
      # heat_map: heat_map,
      # week_chart: week_chart,
      # group_week_chart: group_week_chart,
      # board_week_chart: board_week_chart,
      most_clicked_words: most_clicked_words,
      last_sign_in_at: last_sign_in_at,
      last_sign_in_ip: last_sign_in_ip,
      current_sign_in_at: current_sign_in_at,
      current_sign_in_ip: current_sign_in_ip,
      sign_in_count: sign_in_count,
      tokens: tokens,
      settings: settings,
      stripe_customer_id: stripe_customer_id,
      unread_messages: messages.where(recipient_id: id, read_at: nil, recipient_deleted_at: nil).count,
    }
  end

  def username
    email.split("@").first
  end

  def slug
    profile&.slug || "#{username}-#{id}".parameterize
  end

  def startup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/vendors/sign-in?username=#{username}"
  end

  def setup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/pro-accounts/#{id}/qr"
  end

  def public_url
    return nil if slug.blank?
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"

    "#{base_url}/u/#{slug}"
  end

  def self.to_csv
    users = all
    csv_column_names = %w[id email name role created_at updated_at plan_type plan_expires_at plan_status tokens stripe_customer_id]
    CSV.generate do |csv|
      csv << csv_column_names
      users.each do |user|
        csv << user.attributes.values_at(*csv_column_names)
      end
    end
  end
end
