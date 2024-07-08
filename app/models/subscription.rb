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
#  price                      :decimal(8, 2)
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

  def self.build_from_stripe_event(data_object)
    puts "Data object: #{data_object.inspect}"
    user_uuid = data_object["client_reference_id"]
    raise "User UUID not found" if user_uuid.nil?
    user = User.find_by(uuid: user_uuid) rescue nil
    raise "User not found" if user.nil?
    expires_at = data_object["current_period_end"] || data_object["expires_at"]
    if expires_at.nil?
      puts "Expires at not found"
      expires_at = Time.now.to_i + 1.month
    end
    user.add_tokens(100)
    user.stripe_customer_id = data_object["customer"]
    user.plan_type = "Pro"
    user.plan_status = data_object["payment_status"] == "paid" ? "active" : "inactive"
    user.plan_expires_at = Time.at(expires_at)
    user.save!
    subscription = Subscription.new
    subscription.user = user
    subscription.stripe_subscription_id = data_object["subscription"]
    subscription.stripe_customer_id = data_object["customer"]
    subscription.stripe_invoice_id = data_object["invoice"]
    subscription.stripe_payment_status = data_object["payment_status"]
    subscription.status = data_object["payment_status"] == "paid" ? "active" : "inactive"
    subscription.price_in_cents = data_object["amount_total"]
    subscription.stripe_client_reference_id = data_object["client_reference_id"]
    subscription.expires_at = Time.at(expires_at)
    subscription
  end

  def cancel
    self.status = "canceled"
    user.plan_status = "active"
    user.plan_expires_at = Time.now
    user.plan_type = "Free"
    user.save!
    self.save
  end

  def cancel_at_period_end(cancel_at)
    puts "Cancel at period end: #{cancel_at} - #{Time.at(cancel_at)} "
    cancel_at = Time.at(cancel_at)
    self.status = "canceled"
    self.expires_at = cancel_at
    user.plan_status = "pending cancelation"
    user.plan_expires_at = cancel_at
    user.save!
    self.save
  end
end
