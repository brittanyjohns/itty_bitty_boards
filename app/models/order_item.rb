# == Schema Information
#
# Table name: order_items
#
#  id               :bigint           not null, primary key
#  product_id       :bigint           not null
#  order_id         :bigint           not null
#  unit_price       :decimal(, )
#  quantity         :integer
#  total_price      :decimal(, )
#  total_coin_value :integer
#  coin_value       :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class OrderItem < ApplicationRecord
  belongs_to :product
  belongs_to :order

  validates :quantity, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validate :product_present
  validate :order_present

  scope :coin_bundle, -> { where(coin_value: 0) }

  before_save :finalize
  after_save :update_order_totals!

  def unit_price
    if persisted?
      self[:unit_price]
    else
      product.price
    end
  end

  def coin_value
    if persisted?
      self[:coin_value]
    else
      product.coin_value
    end
  end

  def total_price
    unit_price * quantity
  end

  def total_coins
    coin_value * quantity
  end

  def update_order_totals!
    # Using Order's after_save callback
    order.save!
  end

  private

  def product_present
    if product.nil?
      errors.add(:product, "is not valid or is not active.")
    end
  end

  def order_present
    if order.nil?
      errors.add(:order, "is not a valid order.")
    end
  end

  def finalize
    self[:unit_price] = unit_price
    self[:coin_value] = coin_value
    self[:total_coin_value] = total_coins
    self[:total_price] = quantity * self[:unit_price]
  end
end
