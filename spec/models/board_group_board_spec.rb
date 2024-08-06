# == Schema Information
#
# Table name: board_group_boards
#
#  id             :bigint           not null, primary key
#  board_group_id :bigint           not null
#  board_id       :bigint           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
require 'rails_helper'

RSpec.describe BoardGroupBoard, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
