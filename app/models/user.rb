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
#
class User < ApplicationRecord
  pay_customer default_payment_processor: :stripe 
  has_many :boards
  has_many :menus
  has_many :images
  has_many :docs
  has_many :orders
  has_many :openai_prompts
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  include Devise::JWT::RevocationStrategies::JTIMatcher
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :invitable,
         :jwt_authenticatable, jwt_revocation_strategy: self
  has_many :user_docs, dependent: :destroy
  has_many :favorite_docs, through: :user_docs, class_name: 'Doc', source: :doc

  has_secure_token :authentication_token

  scope :admins, -> { where(role: 'admin') }

  after_create :add_welcome_tokens

  DEFAULT_ADMIN_ID = 1

  def self.default_admin
    User.find(DEFAULT_ADMIN_ID)
  end

  def invite_to_team!(team, inviter)
    puts "Inviting user to team"
    result = BaseMailer.team_invitation_email(self, inviter, team).deliver_now
    puts "Email sent: #{result}"
  end

  def add_welcome_tokens
    add_tokens(10)
  end

  def admin?
    role == 'admin'
  end

  def non_menu_boards
    boards.non_menus.order(name: :asc)
  end

  def all_available_images
    Image.where(user_id: [id, nil]).order(label: :desc)
  end

  def is_a_favorite?(doc)
    favorite_docs.include?(doc)
  end

  def can_edit?(model)
    return false unless model
    return true if admin?
    return false if model.respond_to?(:predefined) && model.predefined
    model&.user_id && model&.user_id == id
  end

  def can_favorite?(model)
    return false unless model
    return true if admin? || !model.user_id
    return true if model.user_id == DEFAULT_ADMIN_ID
    model&.user_id && model&.user_id == id
  end

  def remove_tokens(amount)
    update(tokens: tokens - amount)
  end

  def add_tokens(amount)
    update(tokens: tokens + amount)
  end

  def display_doc_for_image(image)
    favorite_docs.where(id: image.docs.pluck(:id)).first
  end

  def self.valid_credentials?(email, password)
    user = find_by(email:)
    user&.valid_password?(password) ? user : nil
  end

end
