class AddScreenshotImportIdToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :board_screenshot_import_id, :bigint
    add_index :boards, :board_screenshot_import_id
  end
end
