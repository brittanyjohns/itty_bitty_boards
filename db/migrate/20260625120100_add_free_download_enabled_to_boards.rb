class AddFreeDownloadEnabledToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :free_download_enabled, :boolean, default: false, null: false
    add_index :boards, :free_download_enabled
  end
end
