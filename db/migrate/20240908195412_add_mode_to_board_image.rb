class AddModeToBoardImage < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :mode, :string, default: "static", if_not_exists: true
    add_column :board_images, :dynamic_board_id, :integer, if_not_exists: true
    add_index :board_images, :dynamic_board_id, if_not_exists: true

    remove_column :docs, :prompt_for_prompt, :string, if_exists: true
  end
end
