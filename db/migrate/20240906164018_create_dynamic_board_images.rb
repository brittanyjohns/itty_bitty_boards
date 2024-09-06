class CreateDynamicBoardImages < ActiveRecord::Migration[7.1]
  def change
    create_table :dynamic_board_images do |t|
      t.integer :image_id
      t.integer :dynamic_board_id
      t.integer :position
      t.jsonb :layout, default: {}

      t.timestamps
    end
  end
end
