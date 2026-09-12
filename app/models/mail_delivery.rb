# frozen_string_literal: true

# One row per outbound message, so "did that email actually send?" is a question
# an admin can answer without SSH.
#
# #820 added the two log lines — `[mail] delivered` carrying the Message-ID and
# `[mail] delivery_failed` — and they answered the question for anyone holding a
# shell on the box. #824 is the same question asked again by someone who does
# not: a failed send was still invisible in the product. This table is those two
# signals persisted, plus the third state the logs skipped over: SUPPRESSED,
# which is what staging does to every message and is otherwise indistinguishable
# from "we never tried".
#
# It stores envelope data only — recipients, sender, subject, Message-ID,
# transport — never a body. That is the same surface the mail log already
# carries, and the Message-ID is the field that makes a row actionable: it is
# the key a Google Workspace Email Log Search takes, which is the only place an
# accepted-then-dropped message is visible.
#
# Every writer is fail-soft. Recording a send must never be able to break one.
# == Schema Information
#
# Table name: mail_deliveries
#
#  id            :bigint           not null, primary key
#  status        :string           not null
#  recipients    :string
#  from_address  :string
#  subject       :string
#  message_id    :string
#  mailer        :string
#  transport     :string
#  reason        :string
#  error_class   :string
#  error_message :text
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
class MailDelivery < ApplicationRecord
  DELIVERED = "delivered"
  FAILED = "failed"
  SUPPRESSED = "suppressed"
  STATUSES = [DELIVERED, FAILED, SUPPRESSED].freeze

  # `mailer` as `ApplicationMailer`'s rescue_from writes it. That rescue is the
  # ONLY writer of the column — `MailDeliveryObserver` is handed a
  # `Mail::Message` and cannot see which mailer action built it — so a
  # DELIVERED or SUPPRESSED invite row carries a subject and a NULL mailer,
  # while a FAILED one carries both. Identification is therefore "either
  # column", which is as tightly as this table can name the invitation without
  # a foreign key it deliberately does not have (#928).
  INVITE_MAILER_ACTION = "BaseMailer#team_invitation_email"

  # A reason string this long is a transport's own sentence, and it rides an
  # API payload rather than a log line.
  REASON_LIMIT = 200

  # How long a row is kept. Long enough to cover a "did my applicant ever get
  # anything?" investigation weeks later, short enough that the table stays a
  # log rather than an archive. Retuned from ENV, no deploy.
  def self.retention_days
    ENV.fetch("MAIL_DELIVERY_RETENTION_DAYS", 90).to_i
  end

  # Kill switch for the write on every send. On by default; set
  # MAIL_DELIVERY_LOG=false in Hatchbox to stop recording without a deploy.
  def self.recording_enabled?
    setting = ENV["MAIL_DELIVERY_LOG"]
    return true if setting.blank?

    ActiveModel::Type::Boolean.new.cast(setting)
  end

  scope :failures, -> { where(status: FAILED) }
  scope :recent_first, -> { order(created_at: :desc) }

  # The invitation subject in every locale the app renders mail in. Not
  # memoized: a locale file is reloaded in development, and this is one short
  # array per roster render.
  def self.team_invitation_subjects
    I18n.available_locales.filter_map { |locale|
      I18n.t("base_mailer.team_invitation_email.subject", locale: locale, default: nil).presence
    }.uniq
  end

  # Rows that look like a team invitation. See INVITE_MAILER_ACTION for why
  # this is an OR rather than a single column.
  def self.team_invitations
    subjects = team_invitation_subjects
    return where(mailer: INVITE_MAILER_ACTION) if subjects.empty?

    where(mailer: INVITE_MAILER_ACTION).or(where(subject: subjects))
  end

  # The newest invite-mail outcome per recipient address for a WHOLE roster, in
  # one query. Keyed by the downcased address; an address with nothing on
  # record is simply absent from the hash, which is what keeps "no information"
  # (never sent, or pruned by PruneMailDeliveriesJob) distinguishable from
  # "delivered" — it must never be inferred as success.
  #
  # `team_invitation_email` addresses exactly one recipient, so `recipients`
  # holds that single address and an EQUALITY match is both correct and able to
  # use `index_mail_deliveries_on_recipients` — a `LOWER(recipients)` match
  # would seq-scan the table on every roster render. Case is not a hazard here:
  # Devise's `case_insensitive_keys` downcases `users.email` before save and
  # the mailer addresses that exact string, so the two are the same bytes. The
  # downcased candidate is belt for anything written before that.
  #
  # DISTINCT ON is what makes this one query rather than one per member: it
  # returns at most one row per address, the newest, instead of every
  # historical invite.
  def self.latest_team_invitations_by_recipient(emails)
    candidates = Array(emails).flat_map { |email|
      address = email.to_s.strip
      [address, address.downcase]
    }.reject(&:blank?).uniq
    return {} if candidates.empty?

    scoped = where(recipients: candidates).team_invitations
    scoped
      .select(Arel.sql("DISTINCT ON (mail_deliveries.recipients) mail_deliveries.*"))
      .order(Arel.sql("mail_deliveries.recipients, mail_deliveries.created_at DESC"))
      .to_a
      # Two rows can differ only in the CASE of their recipient and so survive
      # DISTINCT ON separately; sorting oldest-first means index_by keeps the
      # newest of them for the shared key.
      .sort_by { |row| row.created_at || Time.at(0) }
      .index_by { |row| row.recipients.to_s.strip.downcase }
  end

  # Subject and message id are quietly truncated rather than raising: a message
  # with a pathological header must still send.
  COLUMN_LIMIT = 500

  # The single writer. Returns the row, or nil if recording is off or the write
  # failed — callers ignore the return value, which is the point.
  def self.record(status:, message: nil, mailer: nil, reason: nil, error: nil)
    return nil unless recording_enabled?

    create!(
      status: status,
      recipients: clamp(Array(message&.to).join(", ")),
      from_address: clamp(Array(message&.from).join(", ")),
      subject: clamp(message&.subject),
      message_id: clamp(message&.message_id),
      mailer: clamp(mailer),
      transport: clamp(ActionMailer::Base.delivery_method),
      reason: clamp(reason),
      error_class: clamp(error&.class&.name),
      error_message: error&.message,
    )
  rescue StandardError => e
    # Observability must never break a send — including one that already
    # succeeded, where raising here would turn a delivered message into a
    # Sidekiq retry and send it twice.
    Rails.logger.warn("[mail] delivery record failed: #{e.class}: #{e.message}")
    nil
  end

  # Deletes rows past the retention window. Returns the number removed.
  def self.prune!(older_than: retention_days.days.ago)
    where(created_at: ...older_than).delete_all
  end

  def self.clamp(value)
    value.presence && value.to_s.truncate(COLUMN_LIMIT)
  end
  private_class_method :clamp

  def delivered? = status == DELIVERED
  def failed? = status == FAILED
  def suppressed? = status == SUPPRESSED

  # What to tell a team owner about WHY. `reason` is what the observer writes
  # for a suppression ("staging", "e2e_recipient"); a FAILURE carries no reason
  # at all — ApplicationMailer's rescue_from passes the error instead — and the
  # transport's own words are the thing that separates a bad address from an
  # SMTP outage, so they stand in. Truncated: this lands in an API payload.
  def outcome_reason
    text = reason.presence || error_message.presence || error_class.presence
    text && text.to_s.truncate(REASON_LIMIT)
  end

  # The roster's shape for one outcome (#928). `status` is one of the three
  # STATUSES verbatim, so a client can switch on it; a null `reason` means the
  # row has nothing more to say, which is the normal case for a delivery.
  def invite_delivery_view
    { status: status, reason: outcome_reason, at: created_at&.utc&.iso8601 }
  end
end
