class Board < ApplicationRecord
  belongs_to :user
  belongs_to :parent, polymorphic: true
  has_many :board_images
  has_many :images, through: :board_images

  def remaining_images
    Image.searchable_images_for(self.user).excluding(images)
  end

  def add_image(image_id)
    if image_ids.include?(image_id.to_i)
      puts "image already added"
    else
      new_board_image = board_images.new(image_id: image_id.to_i)
      unless new_board_image.save
        Rails.logger.debug "new_board_image.errors: #{new_board_image.errors.full_messages}"
      end
    end
  end
end
