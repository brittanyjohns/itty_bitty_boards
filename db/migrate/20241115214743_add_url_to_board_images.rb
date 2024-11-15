class AddUrlToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :display_image_url, :string
    add_index :board_images, :display_image_url

    if column_exists?(:board_images, :display_image_url)
      BoardImage.includes(image: :user).all.each do |bi|
        user = bi.image.user
        bi.update(display_image_url: bi.image.display_image_url(user))
      end
    end
  end
end
