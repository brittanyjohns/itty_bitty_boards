class AnalyticsEvent < ApplicationRecord
  belongs_to :user, optional: true

  validates :event_type, presence: true
  validates :occurred_at, presence: true

  before_validation :set_occurred_at

  VALID_EVENT_TYPES = %w[
    user_signed_up
    trial_started
    trial_will_end
    subscription_started
    subscription_canceled
    account_deleted
    board_generated
    ai_board_generated
    ai_generation_failed
    myspeak_profile_viewed
    word_event_logged
  ].freeze

  scope :today, -> { where(occurred_at: Time.zone.now.beginning_of_day..Time.zone.now.end_of_day) }
  scope :since, ->(time) { where("occurred_at >= ?", time) }
  scope :for_event, ->(type) { where(event_type: type) }
  scope :recent, -> { order(occurred_at: :desc) }

  def self.track(event_type, user_id: nil, metadata: {}, occurred_at: nil)
    create!(
      event_type: event_type.to_s,
      user_id: user_id,
      metadata: metadata,
      occurred_at: occurred_at || Time.current
    )
  rescue => e
    Rails.logger.error "AnalyticsEvent.track failed: #{e.message} (#{event_type})"
    nil
  end

  private

  def set_occurred_at
    self.occurred_at ||= Time.current
  end
end
