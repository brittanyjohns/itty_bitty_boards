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
#

class User < ApplicationRecord
  # Payment and authentication setup
  pay_customer default_payment_processor: :stripe
  include Devise::JWT::RevocationStrategies::JTIMatcher
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :invitable,
         :jwt_authenticatable, jwt_revocation_strategy: self

  # Associations
  has_many :boards
  has_many :menus
  has_many :images
  has_many :docs
  has_many :user_docs, dependent: :destroy
  has_many :orders
  has_many :openai_prompts
  has_many :team_users
  belongs_to :current_team, class_name: "Team", optional: true
  has_many :word_events
  has_secure_token :authentication_token

  # Scopes
  scope :admin, -> { where(role: "admin") }
  scope :with_artifacts, -> { includes(user_docs: { doc: { image_attachment: :blob } }, docs: { image_attachment: :blob }) }

  # Constants
  DEFAULT_ADMIN_ID = self.admin.first&.id

  # Callbacks
  before_save :set_default_settings, unless: :settings?
  after_create :add_welcome_tokens

  # Methods for user settings
  def set_default_settings
    voice_settings = { name: "echo", speed: 1, pitch: 1, volume: 1, rate: 1, language: "en-US" }
    self.settings = { voice: voice_settings }
    save
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

  def api_view
    { user: self, boards: boards }
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

  def display_doc_for_image(image)
    user_docs.find_by(image_id: image.id)&.doc
    # Doc.with_attached_image
    #    .joins(:user_docs)
    #    .where(user_docs: { user_id: id })
    #    .where(id: image.docs.select(:id))
    #    .where(user_id: id)
    #    .first
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

  def to_s
    display_name
  end
  require 'mailgun-ruby'

  def test_mailgun

    # First, instantiate the Mailgun Client with your API key
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY']

    # Define your message parameters
    message_params =  { from: 'brittany@speakanyway.com',
                        to:   'bhannajohns@gmail.com',
                        subject: 'The Ruby SDK is awesome!',
                        text:    'It is really easy to send a message!'
                      }

    # Send your message through the client
    mg_client.send_message 'mail.speakanyway.com', message_params
  end
end
