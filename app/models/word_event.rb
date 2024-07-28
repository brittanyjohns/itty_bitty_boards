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
  belongs_to :child_account, optional: true

  def self.session_analysis
    # Define a session as a series of clicks within a certain time window, e.g., 30 minutes
    session_gap = 30.minutes
    @user_sessions = select("user_id, word, previous_word, timestamp, 
                                       LAG(timestamp) OVER (PARTITION BY user_id ORDER BY timestamp) AS previous_timestamp")
      .to_a.group_by(&:user_id)
      .transform_values do |events|
      events.chunk_while { |prev, curr| curr.timestamp - prev.timestamp <= session_gap }
    end
  end

  def self.sessions_for_user(user_id)
    session_gap = 30.minutes
    select("word, previous_word, timestamp, 
            LAG(timestamp) OVER (ORDER BY timestamp) AS previous_timestamp")
      .where(user_id: user_id)
      .chunk_while { |prev, curr| curr.timestamp - prev.timestamp <= session_gap }
  end
end
