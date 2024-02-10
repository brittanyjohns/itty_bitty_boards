# == Schema Information
#
# Table name: orders
#
#  id               :bigint           not null, primary key
#  subtotal         :decimal(, )
#  tax              :decimal(, )
#  shipping         :decimal(, )
#  total            :decimal(, )
#  status           :integer          default("in_progress")
#  user_id          :bigint           not null
#  total_coin_value :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
require "test_helper"

class OrderTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
