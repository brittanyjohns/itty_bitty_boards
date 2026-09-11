# == Schema Information
#
# Table name: events
#
#  id                 :bigint           not null, primary key
#  name               :string
#  slug               :string
#  date               :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  promo_code         :string
#  promo_code_details :string
#
class Event < ApplicationRecord
  has_many :contest_entries, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  # before_validation (not before_create) so a blank slug is auto-derived from
  # name in time for the presence/uniqueness validation above to see it.
  before_validation :set_slug

  def set_slug
    if slug.blank?
      self.slug = name.to_s.parameterize
    else
      self.slug = slug.parameterize
    end
  end

  def winner
    contest_entries.find { |entry| entry.winner? }
  end

  # Safe for unauthenticated callers: no entrant PII, no winner fields.
  # See brittanyjohns/itty_bitty_boards#908.
  def public_view
    {
      id: id,
      name: name,
      slug: slug.parameterize,
      date: date,
      promo_code: promo_code,
      promo_code_details: promo_code_details,
      public_url: public_url,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  # Admin-only: everything in public_view plus the entrant list and winner.
  def admin_view
    entries = contest_entries.order(created_at: :desc).to_a
    won_by = entries.find(&:winner?)

    public_view.merge(
      entries_count: entries.size,
      winner: won_by&.api_view,
      winner_name: won_by&.name,
      winner_email: won_by&.email,
      contest_entries: entries.map(&:api_view),
    )
  end

  def public_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/events/#{slug.parameterize}"
  end
end
