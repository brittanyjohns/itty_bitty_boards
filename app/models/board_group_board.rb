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
class BoardGroupBoard < ApplicationRecord
  belongs_to :board_group
  belongs_to :board
end
