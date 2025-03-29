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

  def api_view(viewing_user = nil)
    {
      id: id,
      user_id: user_id,
      user_email: user.email,
      child_username: child_account&.username,
      word: word,
      can_edit: user == viewing_user,
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
    ActiveRecord::Base.logger.silence do
      image&.part_of_speech
    end
  end

  def self.grouped_by_hour(last: 24)
    self.group_by_hour(:created_at, last: last).count
  end

  def self.grouped_by_day(last: 7)
    self.group_by_day(:created_at, last: last).count
  end

  def self.set_missing_image_ids
    without_image = WordEvent.where(image_id: nil)
    without_image.each do |event|
      user = event.user || event.child_account&.user
      image = Image.find_by(label: event.word, user_id: [user.id, nil])
      event.update(image_id: image&.id)
    end
  end
end
