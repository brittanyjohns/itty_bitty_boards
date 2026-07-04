# app/sidekiq/mailchimp_upsert_lead_job.rb
# Syncs an anonymous free-board-download DownloadLead to Mailchimp as a marketing
# lead. Mirrors the structure of MailchimpUpsertSubscriberJob but works off a raw
# email (no User). Updates the lead's mailchimp_status so the sync outcome is
# auditable.
class MailchimpUpsertLeadJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true

  LEAD_TAG = "BoardDownloadLead".freeze

  def perform(download_lead_id)
    lead = DownloadLead.find_by(id: download_lead_id)
    return unless lead

    MailchimpService.new.record_lead(
      email: lead.email,
      name: lead.name,
      tags: [LEAD_TAG],
    )

    lead.update(mailchimp_status: "synced")
  rescue MailchimpMarketing::ApiError => e
    Rails.logger.error("[Mailchimp] lead upsert API error: #{e.status} #{e.detail || e.message}")
    lead&.update(mailchimp_status: "failed")
    # Only retry transient failures (rate limiting / 5xx). A permanent 4xx —
    # e.g. an audience "required merge field" the config demands but a bare
    # email lead can't supply (the ADDRESS 400 that flooded error tracking) —
    # fails identically on every retry, so re-raising just burns the retry
    # budget into the Dead set and re-surfaces the same untriaged exception.
    raise if transient_error?(e)
  end

  private

  # A nil status means we never got an HTTP response (network/timeout), which is
  # worth retrying. Otherwise only 429 (rate limited) and 5xx are transient.
  def transient_error?(error)
    status = error.status
    return true if status.nil?

    status == 429 || status >= 500
  end
end
