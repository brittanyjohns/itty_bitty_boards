# == Schema Information
#
# Table name: word_events
#
#  id            :bigint           not null, primary key
#  user_id       :bigint           not null
#  word          :string
#  previous_word :string
#  board_id      :integer
#  team_id       :integer
#  timestamp     :datetime
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
class WordEvent < ApplicationRecord
  belongs_to :user
end
