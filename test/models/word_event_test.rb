# == Schema Information
#
# Table name: word_events
#
#  id               :bigint           not null, primary key
#  user_id          :bigint           not null
#  word             :string
#  previous_word    :string
#  board_id         :integer
#  team_id          :integer
#  timestamp        :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  child_account_id :bigint
#  image_id         :integer
#
require "test_helper"

class WordEventTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
