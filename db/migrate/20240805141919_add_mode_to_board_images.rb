class AddModeToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :mode, :string, default: "speak"
    add_column :board_images, :label, :string
    add_column :board_images, :display_label, :string
    add_column :board_images, :predictive_board_id, :integer
  end
end
