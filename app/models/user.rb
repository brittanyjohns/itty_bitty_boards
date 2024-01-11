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
#
class User < ApplicationRecord
  has_many :boards
  has_many :menus
  has_many :images
  has_many :docs
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable
  has_many :user_docs, dependent: :destroy
  has_many :favorite_docs, through: :user_docs, source: :doc

  def admin?
    role == 'admin'
  end

  def is_a_favorite?(doc)
    favorite_docs.include?(doc)
  end

  def can_edit?(model)
    return true if admin? || !model.user_id
    model.user_id && model.user_id == id
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

end
