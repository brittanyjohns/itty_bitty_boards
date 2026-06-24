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
#
# An audit record of a single public view of a safety (communicator) profile
# page. Written by RecordProfileViewJob after a request to
# API::ProfilesController#public. Two purposes:
#
#   1. Drives the parent "someone viewed your child's safety page" alert.
#   2. Builds a history so unexpected access patterns become visible (the abuse-
#      detection value in issue #384).
#
# `notified: true` marks the views that actually triggered a parent email (at
# most one per profile per hour — see RecordProfileViewJob throttling).
class ProfileView < ApplicationRecord
  belongs_to :profile

  validates :viewed_at, presence: true

  before_validation :set_viewed_at, on: :create

  scope :recent, -> { order(viewed_at: :desc) }
  scope :notified, -> { where(notified: true) }
  scope :since, ->(time) { where("viewed_at >= ?", time) }

  private

  def set_viewed_at
    self.viewed_at ||= Time.current
  end
end
