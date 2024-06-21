class AddDisplayImageUrlToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :display_image_url, :string
    remove_column :boards, :display_image_id, :integer
  end
end
