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
#

class User < ApplicationRecord
  # Payment and authentication setup
  pay_customer default_payment_processor: :stripe
  include Devise::JWT::RevocationStrategies::JTIMatcher
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :invitable, :trackable,
         :jwt_authenticatable, jwt_revocation_strategy: self

  # Associations
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

  # Scopes
  scope :admin, -> { where(role: "admin") }
  scope :pro, -> { where(plan_type: "pro") }
  scope :free, -> { where(plan_type: "free") }
  scope :non_admin, -> { where.not(role: "admin") }
  scope :with_artifacts, -> { includes(user_docs: { doc: { image_attachment: :blob } }, docs: { image_attachment: :blob }) }

  # Constants
  # DEFAULT_ADMIN_ID = self.admin.first&.id
  DEFAULT_ADMIN_ID = Rails.env.development? ? 2 : 1

  # Callbacks
  before_save :set_default_settings, unless: :settings?
  after_create :add_welcome_tokens
  # after_create :create_dynamic_default_board
  before_validation :set_uuid, on: :create
  before_save :ensure_settings, unless: :has_all_settings?

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

  def clear_custom_default_board
    custom_board = dynamic_default_board
    custom_board.destroy! if custom_board && custom_board.user_id == id
    self.settings["dynamic_board_id"] = nil
    save
  end

  def dynamic_default_board
    Board.find_by(id: settings["dynamic_board_id"]&.to_i)
  end

  def self.without_custom_predictive_board
    # search user setting for predictive_default_id
    self.where("settings->>'dynamic_board_id' IS NULL")
  end

  def self.fix_user_predictive_default_boards
    self.non_admin.each do |user|
      user.fix_user_predictive_default_board
    end
  end

  def fix_user_predictive_default_board
    custom_board = dynamic_default_board

    if custom_board.nil? || custom_board&.id == Board.predictive_default_id
      puts "Creating dynamic default board for user #{id}"
      custom_board = create_dynamic_default_board
    else
      puts "Checking dynamic default board for user #{id}"
      if custom_board.images.count < 10
        custom_board.destroy
        custom_board = create_dynamic_default_board
      end
    end
    custom_board
  end

  def required_settings
    %w[voice wait_to_speak disable_audit_logging enable_image_display enable_text_display show_labels show_tutorial]
  end

  def has_all_settings?
    required_settings.all? { |setting| settings[setting] }
  end

  def ensure_settings
    self.settings = {} unless settings
    required_settings.each do |setting|
      settings[setting] = true if settings[setting].nil?
    end
  end

  def create_dynamic_default_board
    Board.create_dynamic_default_for_user(self)
  end

  # Methods for user settings
  def set_default_settings
    voice_settings = { name: "alloy", speed: 1.0, pitch: 1.0, volume: 1.0, rate: 1.0, language: "en-US" }
    self.settings = { voice: voice_settings, wait_to_speak: false, disable_audit_logging: false,
                      enable_image_display: true, enable_text_display: true, show_labels: true, show_tutorial: true }
    save
  end

  def predictive_boards
    boards.predictive.includes(:parent, :board_images).order(name: :asc)
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
    # image = Image.includes(:docs).find_by(id: image_id)
    # return [] unless image
    # docs = image.docs.where(user_id: id)
    # return docs if docs.present?
    # docs = image.docs.where(user_id: [nil, DEFAULT_ADMIN_ID])
    # return docs if docs.present?
    # []

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
    BaseMailer.team_invitation_email(self, inviter, team).deliver_now
  end

  def send_welcome_email
    UserMailer.welcome_email(self).deliver_now
    AdminMailer.new_user_email(self).deliver_now
  end

  def subscription_expired?
    plan_expires_at && plan_expires_at < Time.now
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

  def to_s
    display_name
  end

  TRAIL_PERIOD = 8.days

  def free_trial?
    free? && created_at > TRAIL_PERIOD.ago
  end

  def trial_expired?
    free? && created_at < TRAIL_PERIOD.ago
  end

  def trial_expired_at
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

  def api_view
    view = self.as_json
    view["admin"] = admin?
    view["free"] = free?
    view["pro"] = pro?
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
    view["dynamic_board_id"] = settings["dynamic_board_id"]
    view["global_board_id"] = Board.predictive_default_id
    view["has_dynamic_default"] = dynamic_default_board.present?
    view["startup_board_group_id"] = settings["startup_board_group_id"]
    view["boards"] = boards.order(name: :asc).map(&:user_api_view)
    view["board_groups"] = board_groups.order(name: :asc).map(&:user_api_view)
    view["dynamic_boards"] = dynamic_boards.map(&:user_api_view)
    view
  end
end
