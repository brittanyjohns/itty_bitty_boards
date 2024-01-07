class AddBoardIdToDocs < ActiveRecord::Migration[7.1]
  def change
    add_column :docs, :board_id, :integer
    add_column :docs, :user_id, :integer
    add_index :docs, :user_id
  end
end
