# == Schema Information
#
# Table name: subscriptions
#
#  id                         :bigint           not null, primary key
#  user_id                    :bigint           not null
#  stripe_subscription_id     :string
#  stripe_plan_id             :string
#  status                     :string
#  expires_at                 :datetime
#  price_in_cents             :integer
#  interval                   :string           default("month")
#  stripe_customer_id         :string
#  interval_count             :integer          default(1)
#  stripe_invoice_id          :string
#  stripe_client_reference_id :string
#  stripe_payment_status      :string
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#
class Subscription < ApplicationRecord
  belongs_to :user

  scope :active, -> { where(status: "active") }
  scope :inactive, -> { where(status: "inactive") }
  scope :canceled, -> { where(status: "canceled") }
  scope :expiring_soon, -> { where("expires_at < ?", Time.now + 1.week) }
  scope :expired, -> { where("expires_at < ?", Time.now) }
end
