# == Schema Information
#
# Table name: team_boards
#
#  id         :bigint           not null, primary key
#  board_id   :bigint           not null
#  team_id    :bigint           not null
#  allow_edit :boolean          default(FALSE)
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class TeamBoard < ApplicationRecord
  belongs_to :board
  belongs_to :team
end
