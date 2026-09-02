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
class MailDelivery < ApplicationRecord
  DELIVERED = "delivered"
  FAILED = "failed"
  SUPPRESSED = "suppressed"
  STATUSES = [DELIVERED, FAILED, SUPPRESSED].freeze

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
end
