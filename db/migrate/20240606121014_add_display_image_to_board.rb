class AddDisplayImageToBoard < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :display_image_id, :integer
  end
end
