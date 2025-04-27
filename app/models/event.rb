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

  before_create :set_slug

  def set_slug
    if slug.blank?
      self.slug = name.parameterize
    else
      self.slug = slug.parameterize
    end
  end

  def winner
    contest_entries.find { |entry| entry.winner? }
  end

  def api_view
    {
      id: id,
      name: name,
      slug: slug.parameterize,
      promo_code: promo_code,
      promo_code_details: promo_code_details,
      date: date,
      public_url: public_url,
      created_at: created_at,
      updated_at: updated_at,
      contest_entries: contest_entries.map(&:api_view),
      winner_name: winner ? winner.name : nil,
      winner_email: winner ? winner.email : nil,
    }
  end

  def public_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/events/#{slug.parameterize}"
  end
end
