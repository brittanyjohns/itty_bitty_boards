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
#  vendor_id        :bigint
#  profile_id       :bigint
#  data             :jsonb
#  board_group_id   :bigint
#  board_image_id   :bigint
#
class WordEvent < ApplicationRecord
  belongs_to :user
  belongs_to :image, optional: true
  belongs_to :board, optional: true
  belongs_to :team, optional: true
  belongs_to :child_account, optional: true
  belongs_to :vendor, optional: true
  belongs_to :profile, optional: true
  belongs_to :board_group, optional: true
  belongs_to :board_image, optional: true

  include ActionView::Helpers::DateHelper

  before_save :set_child_account!

  def set_child_account!
    return if child_account_id.present?
    return unless profile_id.present?
    profile = Profile.find_by(id: profile_id)
    return unless profile.present? && profile.profileable_type == "ChildAccount"
    self.child_account = profile.profileable
    self.child_account_id = child_account.id if child_account.present?
    Rails.logger.info "Setting child_account_id to #{child_account_id} for WordEvent ID: #{id}" if child_account_id.present?
    save
  rescue StandardError => e
    Rails.logger.error "Error setting child_account for WordEvent ID: #{id}, Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  def api_view(viewing_user = nil)
    time_ago = time_ago_in_words(timestamp) if timestamp.present?
    {
      id: id,
      user_id: user_id,
      user_email: user.email,
      child_username: child_account&.username,
      board_group_id: board_group_id,
      board_image_id: board_image_id,
      profile_id: profile&.id,
      word: word,
      can_edit: user == viewing_user,
      previous_word: previous_word,
      board_id: board_id,
      image_id: image_id,
      team_id: team_id,
      part_of_speech: part_of_speech,
      timestamp: timestamp,
      time_ago_in_words: time_ago,
      board_name: board&.name,
      ip_address: data&.dig("ip"),
      location: data&.dig("location"),
      data: data,
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
