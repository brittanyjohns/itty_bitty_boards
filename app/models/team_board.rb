# == Schema Information
#
# Table name: team_boards
#
#  id            :bigint           not null, primary key
#  board_id      :bigint           not null
#  team_id       :bigint           not null
#  allow_edit    :boolean          default(FALSE)
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  created_by_id :bigint
#
class TeamBoard < ApplicationRecord
  belongs_to :board
  belongs_to :team
  belongs_to :created_by, class_name: "User", foreign_key: "created_by_id", optional: true

  # A board sits on a team at most once. Backstop for the unique index; the
  # index is the enforcement, this is the friendly 422.
  #
  # This is not tidiness. `allow_edit` lives on this row, so a duplicated pair
  # would let a grant be read from one row while a revoke removed the other —
  # a revoke that silently does not revoke.
  validates :board_id, uniqueness: { scope: :team_id }
end
