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
#  lead_source        :string
#  time_zone          :string           default("America/Chicago"), not null
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

  # The drawing a lead with `source` should be entered into right now, or nil.
  #
  # The app time zone is UTC (config.time_zone is commented out in
  # config/application.rb), so `at` MUST be converted into the event's own
  # time_zone before taking the calendar day — a booth submission at 23:30 CT
  # is already "tomorrow" in UTC and would otherwise land on the wrong day.
  # The `date` column is a string holding the event's local ISO day. #910
  def self.drawing_for(source:, at: Time.current)
    return nil if source.blank?

    where(lead_source: source).find do |event|
      event.date.present? && event.date == event.local_date(at)
    end
  end

  def local_date(at = Time.current)
    at.in_time_zone(time_zone.presence || "America/Chicago").to_date.iso8601
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
      lead_source: lead_source,
      time_zone: time_zone,
      entries_count: entries.size,
      eligible_count: entries.count(&:eligible?),
      winner: won_by&.api_view,
      winner_name: won_by&.name,
      winner_email: won_by&.email,
      contest_entries: entries.map(&:api_view),
    )
  end

  # AdminEventListItem[] for admin/events#index: admin_view minus the heavy
  # `contest_entries` array and `winner` object. Deliberately NOT admin_view
  # per row — that loads and serializes every entry of every event (N+1). One
  # query fetches just the entry columns the counts and winner names need. #910
  def self.admin_list_view(events)
    events = events.to_a
    entries_by_event = ContestEntry
      .where(event_id: events.map(&:id))
      .select(:id, :event_id, :name, :email, :winner, :excluded, :won_at)
      .group_by(&:event_id)

    events.map do |event|
      entries = entries_by_event[event.id] || []
      won_by = entries.find(&:winner?)

      event.public_view.merge(
        lead_source: event.lead_source,
        time_zone: event.time_zone,
        entries_count: entries.size,
        eligible_count: entries.count(&:eligible?),
        winner_name: won_by&.name,
        winner_email: won_by&.email,
      )
    end
  end

  def public_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/events/#{slug.parameterize}"
  end
end
