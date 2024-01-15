# == Schema Information
#
# Table name: boards
#
#  id          :bigint           not null, primary key
#  user_id     :bigint           not null
#  name        :string
#  parent_type :string           not null
#  parent_id   :bigint           not null
#  description :text
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class Board < ApplicationRecord
  belongs_to :user
  belongs_to :parent, polymorphic: true
  has_many :board_images, dependent: :destroy
  has_many :images, through: :board_images
  has_many :docs

  scope :for_user, ->(user) { where(user: user) }
  scope :menus, -> { where(parent_type: "Menu") }
  scope :non_menus, -> { where.not(parent_type: "Menu") }

  def remaining_images
    Image.searchable_images_for(self.user).excluding(images)
  end

  def words
    if parent_type == "Menu"
      ["please","thank you", "yes", "no", "and", "help"]
    else
      ["I", "want", "to", "go", "a", "and", "yes", "no"]
    end
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
