# A DownloadLead is captured when an anonymous (not-signed-in) visitor enters
# their email to download a free board PDF. The email is synced to Mailchimp as
# a marketing lead (see MailchimpUpsertLeadJob). board_id is a soft reference
# (belongs_to optional, no DB FK) so a lead survives the board being deleted.
#
# The same public endpoint also carries the Words Within Reach playground
# nomination form (source "playground_nomination"). A nomination is a lead in
# every structural sense — anonymous, email-keyed, arriving with campaign
# metadata — so it reuses this table rather than adding a parallel one. The
# nomination-specific fields (park, city, role, why, sponsor interest) live in
# the schema-free `data` jsonb column, so no migration is involved.
class DownloadLead < ApplicationRecord
  # Default capture source when the client doesn't send one.
  DEFAULT_SOURCE = "free_download".freeze

  # Words Within Reach playground nomination. Discriminates nominations from the
  # free-download funnel everywhere `source` is read.
  NOMINATION_SOURCE = "playground_nomination".freeze

  # Mailchimp sync lifecycle (mailchimp_status column). Set by
  # MailchimpUpsertLeadJob: starts "pending", → "synced" on success / "failed".
  # "skipped" is terminal and set without ever enqueuing the job — it means the
  # lead never consented to marketing, so there is nothing to retry or fix. It
  # exists so consent-less leads don't sit in mailchimp_pending forever and read
  # as a broken sync in Mission Control.
  MAILCHIMP_PENDING = "pending".freeze
  MAILCHIMP_SYNCED  = "synced".freeze
  MAILCHIMP_FAILED  = "failed".freeze
  MAILCHIMP_SKIPPED = "skipped".freeze

  belongs_to :board, optional: true

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  before_validation :default_source

  after_create :notify_admin_of_nomination, if: :nomination?

  scope :for_source, ->(source) { where(source: source) }
  scope :nominations, -> { where(source: NOMINATION_SOURCE) }
  scope :mailchimp_pending, -> { where(mailchimp_status: MAILCHIMP_PENDING) }
  scope :mailchimp_synced,  -> { where(mailchimp_status: MAILCHIMP_SYNCED) }
  scope :mailchimp_failed,  -> { where(mailchimp_status: MAILCHIMP_FAILED) }
  scope :mailchimp_skipped, -> { where(mailchimp_status: MAILCHIMP_SKIPPED) }

  def nomination?
    source == NOMINATION_SOURCE
  end

  # Explicit marketing consent, captured as an opt-in checkbox on the landing
  # page and stored in `data`. Absent, blank, or unparseable means no consent —
  # this deliberately fails closed.
  def marketing_opt_in?
    ActiveModel::Type::Boolean.new.cast(nomination_field(:marketing_opt_in)) || false
  end

  # Nominating a playground is not subscribing to a newsletter, so a nomination
  # only reaches Mailchimp when the nominator ticked the box. Every pre-existing
  # funnel (free_download, classroom_kit, ctg) is unchanged: those visitors
  # entered an email specifically to be sent something, and they still sync.
  def sync_to_mailchimp?
    return marketing_opt_in? if nomination?

    true
  end

  # Nil-safe reader for the jsonb payload, so a mailer or admin view can render a
  # partially filled nomination without guarding every field.
  def nomination_field(key)
    return nil unless data.is_a?(Hash)

    data[key.to_s].presence
  end

  private

  def default_source
    self.source = DEFAULT_SOURCE if source.blank?
  end

  # Mirrors FeedbackItem#send_admin_notification — a nomination nobody sees is
  # worthless, and there is no admin UI for these yet. deliver_later keeps the
  # mail off the request path; a mail failure must never lose the record, which
  # is why this rescues rather than letting the after_create roll the row back.
  def notify_admin_of_nomination
    AdminMailer.new_nomination_email(self).deliver_later
  rescue StandardError => e
    Rails.logger.error("[Nomination] admin notification failed for lead #{id}: #{e.message}")
  end
end
