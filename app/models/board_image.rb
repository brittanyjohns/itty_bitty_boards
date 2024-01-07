# == Schema Information
#
# Table name: board_images
#
#  id         :bigint           not null, primary key
#  board_id   :bigint           not null
#  image_id   :bigint           not null
#  position   :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class BoardImage < ApplicationRecord
  belongs_to :board
  belongs_to :image

  def label
    image.label
  end
end
