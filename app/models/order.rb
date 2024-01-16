# == Schema Information
#
# Table name: orders
#
#  id               :bigint           not null, primary key
#  shipping         :decimal(, )
#  status           :integer          default("in_progress")
#  subtotal         :decimal(, )
#  tax              :decimal(, )
#  total            :decimal(, )
#  total_coin_value :integer          default(0)
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_orders_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Order < ApplicationRecord
  belongs_to :user
  has_many :order_items, dependent: :destroy
  before_save :update_totals

  enum :status, [:in_progress, :placed, :shipped, :cancelled, :failed, :locked]

  def subtotal
    order_items.includes(:product).collect { |oi| oi.valid? ? (oi.quantity * oi.unit_price) : 0 }.sum
  end

  def total_coin_value
    order_items.includes(:product).collect { |oi| oi.valid? ? (oi.quantity * oi.coin_value) : 0 }.sum
  end

  private

  def update_totals
    self.subtotal = subtotal
    self.total = subtotal # Not worried about shipping or tax at the moment
    self.total_coin_value = total_coin_value
  end
end
