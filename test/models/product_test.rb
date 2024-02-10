# == Schema Information
#
# Table name: products
#
#  id                  :bigint           not null, primary key
#  name                :string
#  price               :decimal(, )
#  active              :boolean
#  product_category_id :bigint           not null
#  description         :text
#  coin_value          :integer
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
require "test_helper"

class ProductTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
