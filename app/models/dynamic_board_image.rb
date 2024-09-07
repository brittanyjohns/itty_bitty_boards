# == Schema Information
#
# Table name: dynamic_board_images
#
#  id               :bigint           not null, primary key
#  image_id         :integer          not null
#  dynamic_board_id :integer          not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class DynamicBoardImage < ApplicationRecord
  attr_accessor :skip_create_voice_audio, :skip_initial_layout
  belongs_to :dynamic_board
  belongs_to :image

  delegate :voice, to: :dynamic_board
  delegate :next_words, to: :image
  delegate :label, to: :image
  delegate :text_color, to: :image
  delegate :status, to: :dynamic_board

  def audio_url
    image.audio_url
  end

  def board_image
    BoardImage.find_by(image_id: image_id, dynamic_board_id: dynamic_board_id)
  end

  def layout
    board_image&.layout || {}
  end

  def clean_up_layout
    new_layout = layout.select { |key, _| ["lg", "md", "sm", "xs", "xxs"].include?(key) }
    update!(layout: new_layout)
  end
end
