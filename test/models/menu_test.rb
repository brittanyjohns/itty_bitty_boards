# == Schema Information
#
# Table name: menus
#
#  id          :bigint           not null, primary key
#  user_id     :bigint           not null
#  name        :string
#  description :text
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
require "test_helper"

class MenuTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
