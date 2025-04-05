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
#
require "csv"

class ContestEntry < ApplicationRecord
  belongs_to :event

  validates :name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :event_id, message: "has already entered this event" }

  def api_view
    {
      id: id,
      name: name,
      email: email,
      data: data,
      event_id: event_id,
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
end
