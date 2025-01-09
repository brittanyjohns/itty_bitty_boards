class AddPredictiveBoardIdToBoardImages < ActiveRecord::Migration[7.1]
  def up
    add_column :board_images, :predictive_board_id, :integer
    add_index :board_images, :predictive_board_id
    BoardImage.includes(:image).all.each do |bi|
      bi.predictive_board_id = bi.image.predictive_board_id
      bi.save
    end
    remove_index :images, :predictive_board_id if index_exists?(:images, :predictive_board_id)
    remove_column :images, :predictive_board_id if column_exists?(:images, :predictive_board_id)
  end

  def down
    add_column :images, :predictive_board_id, :integer
    add_index :images, :predictive_board_id
    BoardImage.includes(:image).all.each do |bi|
      bi.image.update!(predictive_board_id: bi.predictive_board_id)
    end
    remove_index :board_images, :predictive_board_id if index_exists?(:board_images, :predictive_board_id)
    remove_column :board_images, :predictive_board_id if column_exists?(:board_images, :predictive_board_id)
  end
end
