# == Schema Information
#
# Table name: organizations
#
#  id                 :bigint           not null, primary key
#  name               :string
#  slug               :string
#  admin_user_id      :bigint           not null
#  settings           :jsonb
#  stripe_customer_id :string
#  plan_type          :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class Organization < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :teams, dependent: :destroy

  belongs_to :admin_user, class_name: "User", foreign_key: "admin_user_id"

  def api_view(current_user = nil)
    {
      id: id,
      name: name,
      slug: slug,
      admin_user_id: admin_user_id,
      settings: settings,
      stripe_customer_id: stripe_customer_id,
      plan_type: plan_type,
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
