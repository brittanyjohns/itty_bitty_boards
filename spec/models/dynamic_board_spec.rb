# == Schema Information
#
# Table name: dynamic_boards
#
#  id         :bigint           not null, primary key
#  name       :string
#  board_id   :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
require 'rails_helper'

RSpec.describe DynamicBoard, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
