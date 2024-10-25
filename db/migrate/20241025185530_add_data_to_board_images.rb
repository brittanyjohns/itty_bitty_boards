class AddDataToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :data, :jsonb, default: {}
    add_index :board_images, :data, using: :gin
    add_column :boards, :data, :jsonb, default: {}
    add_index :boards, :data, using: :gin
  end
end
