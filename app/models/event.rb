# == Schema Information
#
# Table name: events
#
#  id         :bigint           not null, primary key
#  name       :string
#  slug       :string
#  date       :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class Event < ApplicationRecord
  has_many :contest_entries, dependent: :destroy

  validates :name, presence: true

  def api_view
    {
      id: id,
      name: name,
      slug: slug,
      date: date,
      public_url: public_url,
      created_at: created_at,
      updated_at: updated_at,
      contest_entries: contest_entries.map(&:api_view),
    }
  end

  def public_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/events/#{slug}"
  end
end
