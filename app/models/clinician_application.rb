# A ClinicianApplication is a verified-clinician request for the free
# "SpeakAnyWay for Clinicians" plan (SLP / OT / AT specialist). Applications are
# reviewed manually by an admin — approval flips the applicant's plan_type to
# `clinician` (User callbacks apply the limits + credits). One PENDING
# application per user at a time (partial unique index + model validation); a
# user may re-apply after a denial.
class ClinicianApplication < ApplicationRecord
  PENDING = "pending".freeze
  APPROVED = "approved".freeze
  DENIED = "denied".freeze
  STATUSES = [PENDING, APPROVED, DENIED].freeze

  # Credential types we accept. "other" is a catch-all the admin reviews by hand.
  CREDENTIAL_TYPES = %w[slp ot at_specialist other].freeze

  # Display labels for the credential slugs, shared by the admin dashboard and
  # the admin notification email so the two can't drift.
  CREDENTIAL_LABELS = {
    "slp" => "SLP",
    "ot" => "OT",
    "at_specialist" => "AT Specialist",
    "other" => "Other",
  }.freeze

  belongs_to :user
  belongs_to :reviewed_by, class_name: "User", optional: true

  # Normalize BEFORE validating, so a client sending a display label
  # ("AT specialist", "SLP") is corrected rather than rejected — the web app
  # sent labels until the slugs landed, and an older native build may still.
  # Anything we don't recognize falls back to "other", which is the catch-all
  # an admin reviews by hand anyway; the applicant's own words are preserved in
  # the rest of the application.
  before_validation :normalize_credential_type

  # Every other inbound signal in the app pings an admin; an application that
  # nobody is told about sits in the dashboard until somebody happens to look.
  after_create :notify_admin_of_application

  validates :status, inclusion: { in: STATUSES }
  validates :full_name, presence: true
  validates :credential_type, presence: true, inclusion: { in: CREDENTIAL_TYPES }
  # One pending application per user (belt-and-suspenders with the partial
  # unique index — the DB is the real guard against races).
  validates :user_id, uniqueness: { scope: :status, conditions: -> { where(status: PENDING) }, message: "already has a pending application" }, if: :pending?

  scope :pending, -> { where(status: PENDING) }
  scope :approved, -> { where(status: APPROVED) }
  scope :denied, -> { where(status: DENIED) }

  def pending?
    status == PENDING
  end

  def approved?
    status == APPROVED
  end

  def denied?
    status == DENIED
  end

  def credential_label
    CREDENTIAL_LABELS[credential_type.to_s] || credential_type.presence || "—"
  end

  # "AT specialist" / "SLP" / " ot " → "at_specialist" / "slp" / "ot".
  # Shared with the backfill migration, so both normalize identically.
  def self.normalize_credential_type(value)
    return nil if value.blank?

    slug = value.to_s.strip.downcase.gsub(/[\s-]+/, "_")
    CREDENTIAL_TYPES.include?(slug) ? slug : "other"
  end

  private

  def normalize_credential_type
    return if credential_type.blank?

    self.credential_type = self.class.normalize_credential_type(credential_type)
  end

  # Rescued and logged, never raised: a mailer failure must not roll back the
  # application the clinician just submitted.
  def notify_admin_of_application
    AdminMailer.new_clinician_application_email(self).deliver_later
  rescue StandardError => e
    Rails.logger.error("[ClinicianApplication] admin notification failed for application #{id}: #{e.message}")
  end
end
