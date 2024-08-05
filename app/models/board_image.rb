# == Schema Information
#
# Table name: board_images
#
#  id           :bigint           not null, primary key
#  board_id     :bigint           not null
#  image_id     :bigint           not null
#  position     :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  voice        :string
#  next_words   :string           default([]), is an Array
#  bg_color     :string
#  text_color   :string
#  font_size    :integer
#  border_color :string
#  layout       :jsonb
#  status       :string           default("pending")
#
class BoardImage < ApplicationRecord
  default_scope { order(position: :asc) }
  belongs_to :board, touch: true
  belongs_to :image
  # acts_as_list scope: :board

  before_save :set_defaults
  before_save :create_voice_audio, if: :voice_changed_and_not_existing?
  after_create :set_next_words

  def set_next_words
    return if next_words.present?
    self.next_words = image.next_words
    save
  end

  scope :created_today, -> { where("created_at >= ?", Time.zone.now.beginning_of_day) }

  def voice_changed_and_not_existing?
    x = voice_changed?
    y = !image.existing_voices.include?(voice)
    result = x && y
    puts "\n\nvoice_changed #{x} && !existing_voices.include?(voice) #{y} | -- voice: #{voice}\n -- image: #{image.label}\n\n"
    y
  end

  def label
    image.label
  end

  def board_images
    board.board_images.sort_by(&:position)
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
    { i: id, x: grid_x, y: grid_y, w: 1, h: 1 }
  end

  def calucate_position(x, y)
    x + (y * board.number_of_columns) + 1
  end

  def create_voice_audio
    puts "\nRunning create_voice_audio\n -- image: #{image.label}\n -- voice: #{voice}\n"
    return if image.existing_voices.include?(voice)

    image.find_or_create_audio_file_for_voice(voice)
  end

  def set_defaults
    self.voice = board.voice
  end

  def set_position
    self.position = board_images.count + 1
  end

  def save_initial_layout
    l = board.calucate_grid_layout
    # set_position
    # update!(layout: initial_layout)
  end

  def added_at
    created_at.strftime("%m/%d %I:%M %p")
  end

  def image_last_added_at
    image.docs.last&.created_at&.strftime("%m/%d %I:%M %p")
  end
end
