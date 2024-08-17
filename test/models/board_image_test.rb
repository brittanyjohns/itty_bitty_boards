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
#  audio_url    :string
#
require "test_helper"

class BoardImageTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
