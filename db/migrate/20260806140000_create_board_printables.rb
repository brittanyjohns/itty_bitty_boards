class CreateBoardPrintables < ActiveRecord::Migration[8.0]
  def change
    create_table :board_printables do |t|
      # The ROOT board. When include_subboards is set, board_ids holds the
      # whole walked tree in BFS order; this column is always its first entry.
      t.references :board, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.boolean :include_subboards, null: false, default: false
      t.integer :max_boards, null: false, default: 25
      t.string :topic
      t.integer :page_count
      t.jsonb :board_ids, null: false, default: []
      t.text :error_message

      t.timestamps
    end

    add_index :board_printables, [:board_id, :status]
  end
end
