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
require "test_helper"

class OrderItemTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
