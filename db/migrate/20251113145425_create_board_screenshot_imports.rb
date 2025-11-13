class CreateBoardScreenshotImports < ActiveRecord::Migration[7.1]
  def up
    if table_exists?(:board_image_imports)
      rename_table :board_image_imports, :board_screenshot_imports
    elsif !table_exists?(:board_screenshot_imports)
      create_table :board_screenshot_imports do |t|
        t.references :user, null: false, foreign_key: true
        t.string :name
        t.string :status
        t.integer :guessed_rows
        t.integer :guessed_cols
        t.decimal :confidence_avg
        t.text :error_message
        t.jsonb :metadata

        t.timestamps
      end
    end
  end

  def down
    if table_exists?(:board_image_imports)
      drop_table :board_image_imports
    end
    if table_exists?(:board_screenshot_imports)
      drop_table :board_screenshot_imports
    end
  end
end
