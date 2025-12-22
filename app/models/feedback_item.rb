class FeedbackItem < ApplicationRecord
  belongs_to :user

  FEEDBACK_TYPES = %w[bug feature question praise].freeze
  ROLES = %w[parent slp teacher vendor partner other].freeze

  validates :feedback_type, inclusion: { in: FEEDBACK_TYPES }
  validates :role, inclusion: { in: ROLES }
  validates :message, presence: true
end
