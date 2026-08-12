# app/models/profile_view.rb
# == Schema Information
#
# Table name: profile_views
#
#  id              :bigint           not null, primary key
#  profile_id      :bigint           not null
#  ip_address      :string
#  user_agent      :string
#  approx_location :string
#  geo             :jsonb            not null
#  notified        :boolean          default(FALSE), not null
#  viewed_at       :datetime         not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  view_kind       :string           default("safety"), not null
#
# An audit record of a single gated reveal on a safety (communicator) MySpeak
# page. Written by RecordProfileViewJob. Two purposes:
#
#   1. Drives the parent "someone viewed your child's safety page" alert.
#   2. Builds a history so unexpected access patterns become visible (the abuse-
#      detection value in issue #384).
#
# `view_kind` distinguishes the two reveals the page offers, and only one of
# them can notify:
#
#   "safety" — the emergency-info reveal (medical details + ICE contacts).
#              Logged AND alerts the parent.
#   "care"   — the care-sections reveal (communication, personal care, meals,
#              transportation). Logged, never alerts: this is day-to-day support
#              info, and alerting on it would train parents to ignore the alert
#              that matters.
#
# `notified: true` marks the views that actually triggered a parent email (at
# most one per profile per hour — see RecordProfileViewJob throttling). It is
# therefore always false on a "care" row.
class ProfileView < ApplicationRecord
  belongs_to :profile

  validates :viewed_at, presence: true

  before_validation :set_viewed_at, on: :create

  scope :recent, -> { order(viewed_at: :desc) }
  scope :notified, -> { where(notified: true) }
  scope :since, ->(time) { where("viewed_at >= ?", time) }
  scope :safety_kind, -> { where(view_kind: "safety") }
  scope :care_kind, -> { where(view_kind: "care") }

  private

  def set_viewed_at
    self.viewed_at ||= Time.current
  end
end
