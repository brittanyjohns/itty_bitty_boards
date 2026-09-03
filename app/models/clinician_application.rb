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

  # The credentials for which a license number genuinely EXISTS and is
  # checkable against a state board. For the other two it does not reliably
  # exist at all, so requiring one there is not a gate — it is a barrier that
  # honest applicants clear by typing "N/A" and dishonest ones clear the same
  # way. Every application is reviewed by a human; the field was never the gate.
  LICENSE_REQUIRED_CREDENTIALS = %w[slp ot].freeze

  # Values that mean "I do not have one" dressed up as an answer. Compared
  # against a normalized form (downcased, stripped, inner punctuation and
  # whitespace removed) so "N/A", "n / a", "N.A." and "n\a" all collapse to the
  # same token. Rejected only where a license is REQUIRED — see
  # `license_placeholder?`.
  LICENSE_PLACEHOLDERS = %w[
    na none nil nan null nothing no notapplicable
    unknown unsure tbd pending exempt
    x xx xxx test asdf
    0 00 000 1 123
  ].freeze

  # Offered by every refusal, so the applicant is told what to do instead of
  # only what they may not do. Kept as a constant because the model, the
  # controller error path and the specs all have to say the same thing.
  LICENSE_ALTERNATIVE_HINT =
    "If you don't have one, choose AT Specialist or Other and tell us how to verify you instead."

  belongs_to :user
  belongs_to :reviewed_by, class_name: "User", optional: true

  # Normalize BEFORE validating, so a client sending a display label
  # ("AT specialist", "SLP") is corrected rather than rejected — the web app
  # sent labels until the slugs landed, and an older native build may still.
  # Anything we don't recognize falls back to "other", which is the catch-all
  # an admin reviews by hand anyway; the applicant's own words are preserved in
  # the rest of the application.
  before_validation :normalize_credential_type
  # Runs AFTER credential normalization (declaration order is run order), since
  # whether a placeholder is rejected or quietly dropped depends on the
  # normalized credential.
  before_validation :normalize_license_id

  # Every other inbound signal in the app pings an admin; an application that
  # nobody is told about sits in the dashboard until somebody happens to look.
  after_create :notify_admin_of_application

  validates :status, inclusion: { in: STATUSES }
  validates :full_name, presence: true
  validates :credential_type, presence: true, inclusion: { in: CREDENTIAL_TYPES }
  # `on: :create` — a SUBMISSION is validated when it is submitted; a REVIEW is
  # an update and must never be blocked by it. Applications filed before this
  # rule existed carry no license_id at all (nothing required one), and
  # ClinicianApplications::Reviewer saves the row to approve or deny it — a
  # blanket validation would have made every historical SLP/OT application
  # permanently unapprovable, with the only recovery being to edit the DB.
  validate :license_id_present_when_required, on: :create
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

  def license_required?
    LICENSE_REQUIRED_CREDENTIALS.include?(credential_type.to_s)
  end

  # "N/A" and friends. Public because the admin surfaces read it to explain why
  # an application arrived with no license number.
  def self.license_placeholder?(value)
    return false if value.blank?

    token = normalize_license_token(value)
    # An entry with no letters and no digits at all ("-", "--", ".") is not a
    # license number under any scheme, so it is a placeholder by shape rather
    # than by being on the list.
    return true if token.blank?

    LICENSE_PLACEHOLDERS.include?(token)
  end

  # Downcase, drop everything that isn't a letter or digit. "N / A" and "n.a."
  # both become "na"; a real license ("SLP-40219") keeps enough shape to miss
  # every placeholder.
  def self.normalize_license_token(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, "")
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

  # Trim, and for a credential that does NOT require a license, drop a
  # placeholder rather than storing it: "N/A" in the admin queue is noise that
  # reads like an answer. Where a license IS required the value is left alone so
  # `license_id_present_when_required` can refuse it by name — silently nilling
  # it there would turn a specific "that isn't a license number" into a generic
  # "this field is required".
  def normalize_license_id
    self.license_id = license_id.to_s.strip.presence

    return if license_id.nil?
    return if license_required?

    self.license_id = nil if self.class.license_placeholder?(license_id)
  end

  def license_id_present_when_required
    return unless license_required?

    if license_id.blank?
      errors.add(:license_id, "is required for #{credential_label}. #{LICENSE_ALTERNATIVE_HINT}")
    elsif self.class.license_placeholder?(license_id)
      errors.add(:license_id, "doesn't look like a license or certification number. #{LICENSE_ALTERNATIVE_HINT}")
    end
  end

  # Rescued and logged, never raised: a mailer failure must not roll back the
  # application the clinician just submitted.
  def notify_admin_of_application
    AdminMailer.new_clinician_application_email(self).deliver_later
  rescue StandardError => e
    Rails.logger.error("[ClinicianApplication] admin notification failed for application #{id}: #{e.message}")
  end
end
