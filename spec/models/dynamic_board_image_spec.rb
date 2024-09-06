# == Schema Information
#
# Table name: dynamic_board_images
#
#  id               :bigint           not null, primary key
#  image_id         :integer
#  dynamic_board_id :integer
#  position         :integer
#  layout           :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
require 'rails_helper'

RSpec.describe DynamicBoardImage, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
