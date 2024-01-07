# == Schema Information
#
# Table name: board_images
#
#  id         :bigint           not null, primary key
#  board_id   :bigint           not null
#  image_id   :bigint           not null
#  position   :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
require "test_helper"

class BoardImageTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
