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
class WordEvent < ApplicationRecord
  belongs_to :user
  belongs_to :image, optional: true
  belongs_to :board, optional: true
  belongs_to :team, optional: true
  belongs_to :child_account, optional: true

  def api_view
    {
      id: id,
      user_id: user_id,
      user_email: user.email,
      child_username: child_account&.username,
      word: word,
      previous_word: previous_word,
      board_id: board_id,
      image_id: image_id,
      team_id: team_id,
      part_of_speech: part_of_speech,
      timestamp: timestamp,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  def part_of_speech
    image&.part_of_speech
  end

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

  def self.set_missing_image_ids
    without_image = WordEvent.where(image_id: nil)
    puts "Events without image: #{without_image.count}"
    without_image.each do |event|
      user = event.user || event.child_account&.user
      image = Image.find_by(label: event.word, user_id: [user.id, nil])
      event.update(image_id: image&.id)
    end
  end
end
