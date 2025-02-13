# == Schema Information
#
# Table name: child_accounts
#
#  id                     :bigint           not null, primary key
#  username               :string           default(""), not null
#  name                   :string           default("")
#  encrypted_password     :string           default(""), not null
#  reset_password_token   :string
#  reset_password_sent_at :datetime
#  remember_created_at    :datetime
#  sign_in_count          :integer          default(0), not null
#  current_sign_in_at     :datetime
#  last_sign_in_at        :datetime
#  current_sign_in_ip     :string
#  last_sign_in_ip        :string
#  user_id                :bigint           not null
#  authentication_token   :string
#  settings               :jsonb
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  passcode               :string
#  details                :jsonb
#
class ChildAccount < ApplicationRecord
  # devise :database_authenticatable, :trackable
  # devise :database_authenticatable, :registerable,
  #        :recoverable, :rememberable, :validatable,
  #        authentication_keys: [:username]

  belongs_to :user
  has_many :child_boards, dependent: :destroy
  has_many :boards, through: :child_boards
  has_many :images, through: :boards
  has_many :word_events, dependent: :destroy
  has_secure_token :authentication_token
  has_many :team_accounts, dependent: :destroy
  has_many :teams, through: :team_accounts

  include WordEventsHelper

  validates :passcode, presence: true, on: :create
  validates :passcode, length: { minimum: 6 }, on: :create

  validates :username, presence: true, uniqueness: true

  delegate :display_docs_for_image, to: :user

  scope :alphabetical, -> { order(Arel.sql("LOWER(name) ASC")) }

  def self.valid_credentials?(username, password_to_set)
    account = ChildAccount.find_by(username: username, passcode: password_to_set)
    if account
      puts "Account found: #{account.inspect}"
      account
    else
      Rails.logger.info "Invalid credentials for #{username}"
      nil
    end
  end

  def user_docs
    user.user_docs
  end

  def reset_password(new_password, new_password_confirmation)
    if new_password == new_password_confirmation
      update!(password: new_password, password_confirmation: new_password_confirmation)
    else
      raise "Passwords do not match"
    end
  end

  def self.find_by_token(token)
    find_by(authentication_token: token)
  end

  def self.create_for_user(user, username, password)
    account = new(username: username, password: password, user: user, password_confirmation: password)
    account.save!
    account
  end

  def print_credentials
    puts "UserId: #{user_id} Username: #{username} Password: #{passcode}"
  end

  def can_sign_in?(user_context = nil)
    if user_context && user_context.admin?
      return true
    end

    if self.user.admin?
      return true
    end

    if user
      user.pro? ? true : user.free_trial?
    else
      if self.user.admin?
        return true
      end
      puts "No user provided"
      false
    end
  end

  def admin?
    user.admin?
  end

  def available_boards
    current_board_ids = self.child_boards.distinct.pluck(:board_id)
    current_boards = Board.where(id: current_board_ids)
    user.boards.where.not(id: current_boards.pluck(:id)).order(:name)
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      username: username,
      passcode: passcode,
      can_edit: viewing_user&.admin? || viewing_user&.id == user_id,
      pro: user.pro?,
      free_trial: user.free_trial?,
      admin: user.admin?,
      parent_name: user.display_name,
      name: name,
      heat_map: heat_map,
      teams: teams.map { |t| t.index_api_view(viewing_user) },
      settings: settings,
      details: details,
      user_id: user_id,
      boards: child_boards.map { |cb| { id: cb.id, name: cb.board.name, board_type: cb.board.board_type, board_id: cb.board_id, display_image_url: cb.board.display_image_url } },
      can_sign_in: can_sign_in?,
      available_boards: available_boards.map { |b| { id: b.id, name: b.name, display_image_url: b.display_image_url, board_type: b.board_type } },

    }
  end

  def index_api_view
    {
      id: id,
      username: username,
      name: name,
      parent_name: user.display_name,
      user_id: user_id,
    }
  end
end
