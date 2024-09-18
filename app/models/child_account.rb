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
#
class ChildAccount < ApplicationRecord
  # devise :database_authenticatable, :trackable
  # devise :database_authenticatable, :registerable,
  #        :recoverable, :rememberable, :validatable,
  #        authentication_keys: [:username]

  belongs_to :user
  has_many :child_boards, dependent: :destroy
  has_many :boards, through: :child_boards
  has_secure_token :authentication_token

  validates :passcode, presence: true, on: :create
  validates :passcode, length: { minimum: 6 }, on: :create

  validates :username, presence: true, uniqueness: true

  def self.valid_credentials?(username, password_to_set)
    puts "Checking credentials for #{username} - #{password_to_set}"
    account = ChildAccount.find_by(username: username, passcode: password_to_set)
    if account
      account
    else
      Rails.logger.info "Invalid credentials for #{username}"
      nil
    end
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

  def can_sign_in?(user = nil)
    if user && user.admin?
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

  def api_view
    {
      id: id,
      username: username,
      passcode: passcode,
      parent_name: user.display_name,
      name: name,
      settings: settings,
      user_id: user_id,
      boards: child_boards.map(&:api_view),
      can_sign_in: can_sign_in?,
    }
  end
end
