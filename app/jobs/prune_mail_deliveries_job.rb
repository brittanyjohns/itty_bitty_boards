# frozen_string_literal: true

# Keeps `mail_deliveries` a log rather than an archive. One row is written per
# outbound message, so without this the table grows with send volume forever.
# Retention is MAIL_DELIVERY_RETENTION_DAYS (default 90) — long enough to answer
# "did my applicant ever get anything?" weeks after the fact.
class PruneMailDeliveriesJob
  include Sidekiq::Job
  sidekiq_options queue: "maintenance", retry: 1

  def perform
    removed = MailDelivery.prune!
    Rails.logger.info("[mail] pruned #{removed} mail_deliveries older than #{MailDelivery.retention_days} days")
  end
end
