class AddImageParentToBoards < ActiveRecord::Migration[7.1]
  def up
    add_column :boards, :image_parent_id, :integer
    add_index :boards, :image_parent_id
    Board.where(parent_type: "Image").each do |board|
      board.update(image_parent_id: board.parent_id)
    end
  end

  def down
    remove_column :boards, :image_parent_id
  end
end
