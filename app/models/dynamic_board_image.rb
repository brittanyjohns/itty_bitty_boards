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
  delegate :board, to: :dynamic_board

  def position
    board_image&.position || 0
  end

  def grid_x
    result = nil
    if position
      position_index = position - 1
      result = position_index % board.number_of_columns
    else
      result = 0
    end
    result
  end

  def grid_y
    if position
      result = (position / board.number_of_columns).floor
      result
    else
      0
    end
  end

  def initial_layout
    { "lg" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "md" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "sm" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "xs" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "xxs" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 } }
  end

  def audio_url
    image.audio_url
  end

  def board_image
    bi = BoardImage.find_by(image_id: image_id, board_id: dynamic_board.board_id)
    puts "BoardImage: #{bi.inspect} - #{image_id} - #{dynamic_board_id}"
    bi
  end

  def layout
    board_image&.layout || {}
  end

  def clean_up_layout
    new_layout = layout.select { |key, _| ["lg", "md", "sm", "xs", "xxs"].include?(key) }
    update!(layout: new_layout)
  end
end
