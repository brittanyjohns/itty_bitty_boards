class AddBoardIdToDocs < ActiveRecord::Migration[7.1]
  def change
    add_column :docs, :board_id, :integer
  end
end
