# `team_boards` had no uniqueness on (board_id, team_id), so a board could be
# shared with the same team more than once — `Team#add_board!` looked existing
# rows up by (board, created_by_id), so a second sharer minted a second row.
#
# That matters because `allow_edit` (per-board team edit rights) lives on this
# row: with duplicates a grant reads true from one row while a revoke removes
# only the other, which is a revoke that does not revoke. Make it structural.
#
# `id ASC` keeps the OLDEST row, which preserves the original sharer's
# `created_by_id` — BoardSnapshotService keys the SLP-leaves snapshot on it.
class AddUniqueIndexToTeamBoards < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      DELETE FROM team_boards
      WHERE id NOT IN (
        SELECT DISTINCT ON (board_id, team_id) id
        FROM team_boards
        ORDER BY board_id, team_id, allow_edit DESC, id ASC
      )
    SQL

    add_index :team_boards, [:board_id, :team_id], unique: true,
              name: "index_team_boards_on_board_and_team"
  end

  def down
    remove_index :team_boards, name: "index_team_boards_on_board_and_team"
  end
end
