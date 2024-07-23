# == Schema Information
#
# Table name: child_accounts
#
#  id                     :bigint           not null, primary key
#  username               :string           default(""), not null
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
#
class ChildAccount < ApplicationRecord
  devise :database_authenticatable
  # devise :database_authenticatable, :registerable,
  #        :recoverable, :rememberable, :validatable,
  #        authentication_keys: [:username]

  belongs_to :user
  has_many :child_boards, dependent: :destroy
  has_secure_token :authentication_token

  validates :username, presence: true, uniqueness: true

  def self.valid_credentials?(parent_id, username, password)
    user = User.find_by(id: parent_id)
    puts "User: #{user}"
    return nil unless user

    account = find_by(username: username, user: user)
    puts "Account: #{account.inspect}"
    valid_creds = account&.valid_password?(password) ? account : nil
    puts "Valid Creds: #{valid_creds}"
    valid_creds
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

  def api_view
    {
      id: id,
      username: username,
      user_id: user_id,
      boards: child_boards.map(&:api_view),
    }
  end
end
