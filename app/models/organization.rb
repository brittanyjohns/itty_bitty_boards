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

  def self.create_for_user(user, name)
    organization = Organization.new(name: name, admin_user_id: user.id)
    if organization.save
      user.update(organization_id: organization.id)
      organization
    else
      nil
    end
  end

  def self.find_by_slug(slug)
    find_by(slug: slug)
  end

  def self.find_by_id(id)
    find(id)
  end

  def self.create_stripe_customer(email)
    # Placeholder for Stripe customer creation logic
    "stripe_customer_#{email}"
  end

  def api_view(current_user = nil)
    {
      id: id,
      name: name,
      slug: slug,
      admin_user_id: admin_user_id,
      settings: settings,
      stripe_customer_id: stripe_customer_id,
      plan_type: plan_type,
      users: users.map { |user|
        {
          id: user.id,
          name: user.name,
          email: user.email,
          organization_id: user.organization_id,
          role: user.role,
          created_at: user.created_at,
          updated_at: user.updated_at,
        }
      },
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
