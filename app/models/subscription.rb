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

  def self.build_from_stripe_event(data_object, user_id = nil)
    user_uuid = data_object["client_reference_id"]
    raise "User UUID not found" if user_uuid.nil? && user_id.nil?
    user = User.find_by(uuid: user_uuid) if user_uuid && user_id.nil?
    user = User.find(user_id) if user_id && user.nil?

    raise "User not found" if user.nil?
    expires_at = data_object["current_period_end"] || data_object["expires_at"]
    user.stripe_customer_id = data_object["customer"]
    user.plan_type = get_plan_type(data_object["plan"]["nickname"])
    comm_account_limit = get_communicator_limit(data_object["plan"]["nickname"])
    user.settings ||= {}
    user.settings["communicator_limit"] = comm_account_limit
    user.settings["plan_nickname"] = data_object["plan"]["nickname"]
    user.settings["board_limit"] = get_board_limit(data_object["plan"]["nickname"])
    if data_object["cancel_at_period_end"]
      Rails.logger.info "Canceling at period end"
      user.plan_status = "pending cancelation"
      user.settings["cancel_at"] = Time.at(data_object["cancel_at"])
      user.settings["cancel_at_period_end"] = data_object["cancel_at_period_end"]
    else
      user.plan_status = data_object["status"]
    end
    user.plan_expires_at = Time.at(expires_at)
    user.save!
    stripe_subscription_id = data_object["subscription"]
    subscription = Subscription.find_by(stripe_subscription_id: stripe_subscription_id)
    subscription = Subscription.new unless subscription
    subscription.user = user
    subscription.stripe_subscription_id = stripe_subscription_id
    subscription.stripe_customer_id = data_object["customer"]
    subscription.stripe_invoice_id = data_object["invoice"]
    subscription.stripe_payment_status = data_object["payment_status"]
    subscription.status = data_object["payment_status"] == "paid" ? "active" : "inactive"
    subscription.price_in_cents = data_object["amount_total"]
    subscription.stripe_client_reference_id = data_object["client_reference_id"]
    subscription.expires_at = Time.at(expires_at)
    subscription.save!
    subscription
  end

  def self.get_plan_type(plan)
    return "free" if plan.nil?
    if plan.include?("basic")
      "basic"
    elsif plan.include?("pro")
      "pro"
    elsif plan.include?("plus")
      "plus"
    else
      "free"
    end
  end

  def self.get_communicator_limit(plan_type_name)
    return 0 if plan_type_name.nil?
    plan_name = plan_type_name.downcase.split("_").first
    comm_account_limit = plan_type_name.split("_").last || 1
    if plan_name.include?("basic")
      comm_account_limit = comm_account_limit&.to_i || 1
    elsif plan_name.include?("pro")
      comm_account_limit = comm_account_limit&.to_i || 3
    elsif plan_name.include?("plus")
      comm_account_limit = comm_account_limit&.to_i || 5
    elsif plan_name.include?("premium")
      comm_account_limit = comm_account_limit&.to_i || 10
    else
      comm_account_limit = 0
    end
  end

  def self.get_board_limit(plan_type_name)
    return 0 if plan_type_name.nil?
    plan_name = plan_type_name.downcase.split("_").first
    comm_account_limit = get_communicator_limit(plan_type_name)
    if plan_name.include?("basic")
      comm_account_limit * 25
    elsif plan_name.include?("pro")
      comm_account_limit * 25
    elsif plan_name.include?("plus")
      comm_account_limit * 25
    elsif plan_name.include?("premium")
      comm_account_limit * 25
    else
      0
    end
  end
end

def self.get_token_limit(plan_type_name)
  return 0 if plan_type_name.nil?
  plan_name = plan_type_name.downcase.split("_").first
  token_limit = plan_type_name.split("_").last || 1
  if plan_name.include?("basic")
    token_limit = token_limit&.to_i || 1
  elsif plan_name.include?("pro")
    token_limit = token_limit&.to_i || 3
  elsif plan_name.include?("plus")
    token_limit = token_limit&.to_i || 5
  elsif plan_name.include?("premium")
    token_limit = token_limit&.to_i || 10
  else
    token_limit = 0
  end
end

def self.get_word_event_limit(plan_type_name)
  return 0 if plan_type_name.nil?
  plan_name = plan_type_name.downcase.split("_").first
  word_event_limit = plan_type_name.split("_").last || 1
  if plan_name.include?("basic")
    word_event_limit = word_event_limit&.to_i || 1
  elsif plan_name.include?("pro")
    word_event_limit = word_event_limit&.to_i || 3
  elsif plan_name.include?("plus")
    word_event_limit = word_event_limit&.to_i || 5
  elsif plan_name.include?("premium")
    word_event_limit = word_event_limit&.to_i || 10
  else
    word_event_limit = 0
  end

  def cancel
    self.status = "canceled"
    user.plan_status = "active"
    user.plan_expires_at = Time.now
    user.plan_type = "free"
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
