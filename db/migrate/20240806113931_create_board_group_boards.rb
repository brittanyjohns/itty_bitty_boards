class CreateBoardGroupBoards < ActiveRecord::Migration[7.1]
  def change
    create_table :board_group_boards do |t|
      t.references :board_group, null: false, foreign_key: true
      t.references :board, null: false, foreign_key: true

      t.timestamps
    end
  end
end
