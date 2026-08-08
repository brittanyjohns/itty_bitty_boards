class AddMetadataToAdminBoardBuilds < ActiveRecord::Migration[8.0]
  def change
    add_column :admin_board_builds, :description, :text
    add_column :admin_board_builds, :tags, :string, array: true, default: [], null: false
    add_column :admin_board_builds, :audience, :string
  end
end
