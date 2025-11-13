class CreateBoardScreenshotCells < ActiveRecord::Migration[7.1]
  def change
    create_table :board_screenshot_cells do |t|
      t.references :board_screenshot_import, null: false, foreign_key: true
      t.integer :row
      t.integer :col
      t.string :label_raw
      t.string :label_norm
      t.string :bg_color
      t.decimal :confidence
      t.json :bbox

      t.timestamps
    end
  end
end
