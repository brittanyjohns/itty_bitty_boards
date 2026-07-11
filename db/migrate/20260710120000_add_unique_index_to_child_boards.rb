# Duplicate (board_id, child_account_id) join rows were only ever prevented
# by ad-hoc .exists? checks at the call sites. Dedup what slipped through
# (keep one row per pair — prefer a favorited one, else the oldest), then
# make the invariant structural.
class AddUniqueIndexToChildBoards < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      DELETE FROM child_boards
      WHERE id NOT IN (
        SELECT DISTINCT ON (board_id, child_account_id) id
        FROM child_boards
        ORDER BY board_id, child_account_id, favorite DESC, id ASC
      )
    SQL

    add_index :child_boards, [:board_id, :child_account_id], unique: true,
              name: "index_child_boards_on_board_and_child_account"
  end

  def down
    remove_index :child_boards, name: "index_child_boards_on_board_and_child_account"
  end
end
