class AddStatusToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :status, :string, default: "pending"
  end
end
