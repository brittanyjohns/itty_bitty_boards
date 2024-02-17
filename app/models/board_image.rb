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

  before_save :set_voice
  after_save :create_voice_audio, if: :voice_changed_and_not_existing?

  def voice_changed_and_not_existing?
    voice_changed? && !image.existing_voices.include?(voice)
  end

  def label
    image.label
  end

  def create_voice_audio
    puts "\nRunning create_voice_audio\n -- image: #{image.label}\n -- voice: #{voice}\n"
    return if image.existing_voices.include?(voice)

    image.find_or_create_audio_file_for_voice(board.voice)
    # image.create_voice_audio unless image.
  end

  def set_voice
    self.voice = board.voice
  end
end
