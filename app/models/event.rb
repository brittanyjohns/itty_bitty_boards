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
          created_at: created_at,
          updated_at: updated_at,
          contest_entries: contest_entries.map(&:api_view),
        }
  end
end
