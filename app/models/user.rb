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
#

class User < ApplicationRecord
  # Payment and authentication setup
  pay_customer default_payment_processor: :stripe
  include Devise::JWT::RevocationStrategies::JTIMatcher
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :invitable, :trackable,
         :jwt_authenticatable, jwt_revocation_strategy: self

  # Associations
  belongs_to :organization, optional: true
  has_many :boards, dependent: :destroy
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

  # has_many :sent_messages, class_name: "Message", foreign_key: "sender_id", dependent: :destroy
  # has_many :received_messages, class_name: "Message", foreign_key: "recipient_id", dependent: :destroy

  # Scopes
  scope :admin, -> { where(role: "admin") }
  scope :pro, -> { where(plan_type: "pro") }
  scope :free, -> { where(plan_type: "free") }
  scope :basic, -> { where(plan_type: "basic") }
  scope :plus, -> { where(plan_type: "plus") }

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

  def set_uuid
    return if self.uuid.present?
    self.uuid = SecureRandom.uuid
  end

  def locked?
    locked == true
  end

  def self.clear_all_custom_default_boards
    self.all.each do |user|
      user.clear_custom_default_board
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
    user = User.invite!(email: email, skip_invitation: true)
    if user
      if inviting_user_id
        user.invited_by_id = inviting_user_id
        user.invited_by_type = "User"
        user.send_welcome_invitation_email(inviting_user_id)
      else
        if !slug
          user.send_welcome_email
        else
          user.send_welcome_with_claim_link_email(slug)
        end
      end
      stripe_customer_id ||= user.stripe_customer_id
      if stripe_customer_id.nil?
        stripe_customer_id = User.create_stripe_customer(email)
      end
      user.stripe_customer_id = stripe_customer_id
      user.save
      Rails.logger.info("User created: #{email}")
    else
      Rails.logger.error("User not created: #{email}")
    end
    user
  end

  def recently_used_boards
    recent_word_events = word_events.where("created_at >= ?", 1.week.ago)
    board_ids = recent_word_events.pluck(:board_id).uniq
    boards.where(id: board_ids).limit(10)
  end

  def update_from_stripe_event(data_object, plan_nickname)
    plan_nickname = plan_nickname || "free"
    if data_object["customer"]
      self.stripe_customer_id = data_object["customer"]
    end
    self.settings ||= {}

    if new_user?
      self.plan_type = API::WebhooksHelper.get_plan_type(plan_nickname)
      comm_account_limit = API::WebhooksHelper.get_communicator_limit(plan_nickname)

      self.settings["communicator_limit"] = comm_account_limit if comm_account_limit && !self.settings["communicator_limit"]
      self.settings["plan_nickname"] = plan_nickname
      extra_communicators = settings["extra_communicators"] || 0
      self.settings["extra_communicators"] = extra_communicators
      total_communicators = comm_account_limit + extra_communicators
      self.settings["total_communicators"] = total_communicators
      board_limit = total_communicators * 25
      self.settings["board_limit"] = board_limit
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
  end

  def get_stripe_subscriptions
    begin
      subscriptions = Stripe::Subscription.list({ customer: stripe_customer_id })
      subscriptions.each do |subscription|
        puts "Subscription ID: #{subscription.inspect}"
        puts "-----------------------------"
      end
    rescue Stripe::StripeError => e
      puts "Error retrieving subscriptions: #{e.message}"
    end
    subscriptions
  end

  def clear_custom_default_board
    custom_board = opening_board
    custom_board.destroy! if custom_board && custom_board.user_id == id
    self.settings["opening_board_id"] = nil
    save
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

  def delete_stripe_customer
    return unless stripe_customer_id
    result = Stripe::Customer.delete(stripe_customer_id)
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

  def can_edit_profile?(profile_id)
    return false unless profile_id
    account_profile = Profile.find_by(id: profile_id)
    return false unless account_profile
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

  def is_a_favorite?(doc)
    favorite_docs.include?(doc)
  end

  # Helper methods
  def display_name
    name.blank? ? email : name
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
      puts "Errors: #{new_user.errors.full_messages}"
      raise "User not created: #{new_user.errors.full_messages}"
    end
    # BaseMailer.team_invitation_email(new_user_email, self, team).deliver_now
    BaseMailer.team_invitation_email(new_user.email, self, team).deliver_now

    stripe_customer_id = User.create_stripe_customer(new_user_email)
    new_user.update!(stripe_customer_id: stripe_customer_id)

    new_user
  end

  def send_welcome_email
    begin
      UserMailer.welcome_email(self).deliver_now
      AdminMailer.new_user_email(self).deliver_now
    rescue => e
      Rails.logger.error("Error sending welcome email: #{e.message}")
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

  def subscription_expired?
    plan_expires_at && plan_expires_at < Time.now
  end

  def should_receive_notifications?
    return false if admin?
    return false if locked?
    return false if settings["disable_notifications"] == true
    return false if settings["disable_notifications"] == "true"
    return false if settings["disable_notifications"] == "1"
    return false if settings["disable_notifications"] == 1
    recently_notified = settings["recently_notified"]
    puts "Recently notified: #{recently_notified}"
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
    plan_type.downcase == "pro"
  end

  def free?
    plan_type.downcase == "free"
  end

  def basic?
    plan_type.downcase == "basic"
  end

  def plus?
    plan_type.downcase == "plus"
  end

  def paid_plan?
    plan_type.downcase != "free"
  end

  def professional?
    !free? && !basic?
  end

  def premium?
    plan_type.downcase == "premium"
  end

  def to_s
    display_name
  end

  def should_send_welcome_email?
    return false if admin?
    # if updated today don't send email
    return false if created_at > 1.day.ago
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
    free? && created_at < TRAIL_PERIOD.ago
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
    board_group = BoardGroup.includes(:boards).find_by(id: startup_board_group_id) if startup_board_group_id
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

    view
  end

  def admin_api_view
    view = as_json
    view["admin"] = admin?
    view["free"] = free?
    view["pro"] = pro?
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

  # def api_view
  #   accounts_included = settings["communicator_limit"] || 0
  #   extra_communicators = settings["extra_communicators"] || 0
  #   view = self.as_json
  #   view["plan_expires_at"] = plan_expires_at.strftime("%x") if plan_expires_at
  #   view["admin"] = admin?
  #   view["free"] = free?
  #   view["pro"] = pro?
  #   view["basic"] = basic?
  #   view["plus"] = plus?
  #   view["teams_with_read_access"] = teams_with_read_access.map(&:index_api_view)
  #   view["communicator_accounts"] = communicator_accounts
  #   view["accounts_included"] = accounts_included
  #   view["extra_communicators"] = extra_communicators
  #   view["comm_account_limit"] = accounts_included + extra_communicators
  #   view["supervisor_limit"] = settings["supervisor_limit"] || 0
  #   view["board_limit"] = settings["board_limit"] || 0
  #   view["go_to_words"] = settings["go_to_words"] || Board.common_words
  #   view["go_to_boards"] = go_to_boards.map { |board| { id: board.id, name: board.name, display_image_url: board.display_image_url } }
  #   view["premium"] = premium?
  #   view["paid_plan"] = paid_plan?
  #   view["plan_type"] = plan_type
  #   view["team"] = current_team
  #   view["free_trial"] = free_trial?
  #   view["trial_expired"] = trial_expired?
  #   view["trial_days_left"] = trial_days_left
  #   view["last_sign_in_at"] = last_sign_in_at
  #   view["last_sign_in_ip"] = last_sign_in_ip
  #   view["current_sign_in_at"] = current_sign_in_at
  #   view["current_sign_in_ip"] = current_sign_in_ip
  #   view["sign_in_count"] = sign_in_count
  #   view["tokens"] = tokens
  #   view["phrase_board_id"] = settings["phrase_board_id"]
  #   view["opening_board_id"] = settings["opening_board_id"]
  #   view["has_dynamic_default"] = opening_board.present?
  #   view["startup_board_group_id"] = settings["startup_board_group_id"]
  #   view["boards"] = boards.alphabetical.map { |board| { id: board.id, name: board.name } }
  #   # view["board_groups"] = board_groups.order(name: :asc).map(&:user_api_view)
  #   # view["dynamic_boards"] = dynamic_boards.map(&:user_api_view)
  #   view["heat_map"] = heat_map
  #   view["week_chart"] = week_chart
  #   view["group_week_chart"] = group_week_chart
  #   view["most_clicked_words"] = most_clicked_words
  #   view["display_name"] = display_name
  #   view["unread_messages"] = messages.where(recipient_id: id, read_at: nil, recipient_deleted_at: nil).count
  #   view
  # end
  def api_view
    plan_exp = plan_expires_at&.strftime("%x")
    comm_limit = settings["communicator_limit"] || 0
    extra_comms = settings["extra_communicators"] || 0
    board_limit = settings["board_limit"] || 0
    go_words = settings["go_to_words"] || Board.common_words

    memoized_teams = teams_with_read_access
    memoized_communicators = communicator_accounts
    memoized_boards = boards.alphabetical

    {
      id: id,
      organization_id: organization_id,
      email: email,
      name: name,
      display_name: display_name,
      admin: admin?,
      free: free?,
      pro: pro?,
      basic: basic?,
      plus: plus?,
      premium: premium?,
      paid_plan: paid_plan?,
      plan_type: plan_type,
      plan_expires_at: plan_exp,
      free_trial: free_trial?,
      trial_expired: trial_expired?,
      trial_days_left: trial_days_left,
      accounts_included: comm_limit,
      extra_communicators: extra_comms,
      comm_account_limit: comm_limit + extra_comms,
      supervisor_limit: settings["supervisor_limit"] || 0,
      board_limit: board_limit,
      phrase_board_id: settings["phrase_board_id"],
      opening_board_id: settings["opening_board_id"],
      has_dynamic_default: opening_board.present?,
      startup_board_group_id: settings["startup_board_group_id"],
      current_team: current_team,
      teams_with_read_access: memoized_teams.map(&:index_api_view),
      communicator_accounts: memoized_communicators,
      go_to_words: go_words,
      go_to_boards: go_to_boards.map { |b| { id: b.id, name: b.name, display_image_url: b.display_image_url } },
      boards: memoized_boards.map { |b| { id: b.id, name: b.name } },
      heat_map: heat_map,
      week_chart: week_chart,
      group_week_chart: group_week_chart,
      most_clicked_words: most_clicked_words,
      last_sign_in_at: last_sign_in_at,
      last_sign_in_ip: last_sign_in_ip,
      current_sign_in_at: current_sign_in_at,
      current_sign_in_ip: current_sign_in_ip,
      sign_in_count: sign_in_count,
      tokens: tokens,
      unread_messages: messages.where(recipient_id: id, read_at: nil, recipient_deleted_at: nil).count,
    }
  end
end
