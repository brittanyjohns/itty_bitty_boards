class CreateDynamicBoards < ActiveRecord::Migration[7.1]
  def change
    create_table :dynamic_boards do |t|
      t.string :name
      t.integer :board_id, null: false

      t.timestamps
    end
    add_index :dynamic_boards, :name
    add_index :dynamic_boards, :board_id
  end
end
