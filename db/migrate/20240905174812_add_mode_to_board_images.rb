class AddModeToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :mode, :string, null: false, default: "static"
    add_column :users, :locked, :boolean, null: false, default: false
    add_column :images, :dynamic_board_id, :integer
    add_column :board_images, :dynamic_board_id, :integer
  end
end
