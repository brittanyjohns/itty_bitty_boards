class CreateDynamicBoardImages < ActiveRecord::Migration[7.1]
  def change
    create_table :dynamic_board_images do |t|
      t.integer :image_id, null: false
      t.integer :dynamic_board_id, null: false

      t.timestamps
    end
  end
end
