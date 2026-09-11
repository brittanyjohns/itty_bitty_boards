# == Schema Information
#
# Table name: contest_entries
#
#  id         :bigint           not null, primary key
#  name       :string
#  email      :string
#  data       :jsonb
#  event_id   :bigint           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  winner     :boolean          default(FALSE)
#  won_at     :datetime
#  excluded   :boolean          default(FALSE), not null
#
require "csv"

class ContestEntry < ApplicationRecord
  # Staff / test entrants are never eligible to win the drawing. #909
  STAFF_EMAIL_PATTERNS = [
    /@speakanyway\.com\z/,
    /bhannajohns/,
  ].freeze

  belongs_to :event

  # Normalize before validating so the uniqueness check below compares
  # normalized values, and so `excluded` is set from the normalized email. #909
  before_validation :normalize_email
  before_validation :flag_staff_entry

  validates :name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email,
            uniqueness: { scope: :event_id, case_sensitive: false, message: "has already entered this event" }

  # Emails listed in DRAWING_EXCLUDED_EMAILS (comma separated) are treated the
  # same as staff addresses. Read at call time so the list can change without a
  # deploy of this class.
  def self.excluded_emails
    ENV.fetch("DRAWING_EXCLUDED_EMAILS", "").to_s.split(",").filter_map do |value|
      normalized = value.strip.downcase
      normalized.presence
    end
  end

  def self.staff_email?(value)
    normalized = value.to_s.strip.downcase
    return false if normalized.blank?

    STAFF_EMAIL_PATTERNS.any? { |pattern| pattern.match?(normalized) } ||
      excluded_emails.include?(normalized)
  end

  # Eligible to be drawn: hasn't already won this event, isn't flagged, and
  # isn't a staff/test address. The "already won another event with the same
  # lead_source" rule is cross-event and lives in the controller. #909
  def eligible?
    !winner? && !excluded? && !self.class.staff_email?(email)
  end

  def api_view
    {
      id: id,
      name: name,
      email: email,
      data: data,
      event_id: event_id,
      winner: winner,
      won_at: won_at,
      excluded: excluded,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  def self.to_csv
    entries = all
    CSV.generate do |csv|
      csv << column_names
      entries.each do |entry|
        csv << entry.attributes.values_at(*column_names)
      end
    end
  end

  private

  def normalize_email
    self.email = email.strip.downcase if email.is_a?(String)
  end

  def flag_staff_entry
    self.excluded = true if self.class.staff_email?(email)
  end
end
