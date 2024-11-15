class AddUrlToBoardImages < ActiveRecord::Migration[7.1]
  def up
    add_column :board_images, :display_image_url, :string if !column_exists?(:board_images, :display_image_url)

    add_column :images, :src_url, :string if !column_exists?(:images, :src_url)

    if column_exists?(:images, :src_url)
      Image.with_docs.includes(:board_images, :docs).find_each do |image|
        user = image.user
        updated_src = image.display_image_url(user)

        image.update!(src_url: updated_src)
        image.board_images.each do |board_image|
          board_image.update!(display_image_url: updated_src)
        end
      end
    end
  end

  def down
    remove_column :board_images, :display_image_url if column_exists?(:board_images, :display_image_url)
    remove_column :images, :src_url if column_exists?(:images, :src_url)
  end
end
