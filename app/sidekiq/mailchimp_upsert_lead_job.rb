# app/sidekiq/mailchimp_upsert_lead_job.rb
# Syncs an anonymous free-board-download DownloadLead to Mailchimp as a marketing
# lead. Mirrors the structure of MailchimpUpsertSubscriberJob but works off a raw
# email (no User). Updates the lead's mailchimp_status so the sync outcome is
# auditable.
class MailchimpUpsertLeadJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true

  DEFAULT_LEAD_TAG = "BoardDownloadLead".freeze

  # Applied to every /kit/:slug lead in ADDITION to its per-page tag, so
  # "has ever downloaded a kit" is one durable segment rather than a list of
  # per-page tags that has to be re-enumerated by hand every time Brittany adds
  # a landing page. Deliberately not applied to the SOURCE_TAGS funnels below:
  # those already have segments and automations built against a single tag each,
  # and widening them would silently change who those match.
  KIT_UMBRELLA_TAG = "KitLead".freeze

  # Source-specific Mailchimp tags so distinct lead funnels can be segmented.
  # A "kit_<slug>" source reads its tag off the KitPage row (see #tags_for);
  # anything else falls back to DEFAULT_LEAD_TAG.
  SOURCE_TAGS = {
    "classroom_kit" => "ClassroomKitLead",
    # Closing the Gap 2026 booth capture. Matches the tag the ctg-2026 campaign
    # segment and its welcome automation are already built against.
    "ctg" => "ctg-2026",
    # Words Within Reach playground nominations, so opted-in nominators are a
    # segment of their own rather than mixed into the download list.
    "playground_nomination" => "PlaygroundNomination",
  }.freeze

  def perform(download_lead_id)
    lead = DownloadLead.find_by(id: download_lead_id)
    return unless lead

    # The controller already gates this, but a lead can also be re-enqueued by
    # hand or by a backfill task. Consent is checked at the point of sending so
    # there is exactly one answer to "does this email belong in Mailchimp".
    unless lead.sync_to_mailchimp?
      lead.update(mailchimp_status: DownloadLead::MAILCHIMP_SKIPPED)
      return
    end

    MailchimpService.new.record_lead(
      email: lead.email,
      name: lead.name,
      tags: tags_for(lead),
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

  # Derive the Mailchimp tags from the lead's source so different capture funnels
  # (e.g. the /classroom kit) land under their own segmentable tag.
  #
  # SOURCE_TAGS stays the explicit map for the three hardcoded funnels; a
  # `kit_<slug>` source resolves its tag from the KitPage row instead, which is
  # the whole reason a new landing page needs no deploy.
  #
  # Kit leads get two tags: the per-page one and KIT_UMBRELLA_TAG. The umbrella
  # is keyed on the source PREFIX, not on the page lookup succeeding, so a lead
  # whose landing page was later deleted still counts as a kit lead.
  def tags_for(lead)
    source = lead.source
    return [SOURCE_TAGS[source]] if SOURCE_TAGS.key?(source)
    return [DEFAULT_LEAD_TAG] unless kit_source?(source)

    [kit_page_tag(source) || DEFAULT_LEAD_TAG, KIT_UMBRELLA_TAG]
  end

  def kit_source?(source)
    source.to_s.start_with?(KitPage::LEAD_SOURCE_PREFIX)
  end

  # Never raises. A page deleted after its leads were captured must fall back
  # to the default tag, not fail the job and strand the lead outside Mailchimp.
  def kit_page_tag(source)
    KitPage.for_lead_source(source)&.resolved_mailchimp_tag
  rescue StandardError => e
    Rails.logger.error("[Mailchimp] kit page tag lookup failed for #{source.inspect}: #{e.class}: #{e.message}")
    nil
  end

  # A nil status means we never got an HTTP response (network/timeout), which is
  # worth retrying. Otherwise only 429 (rate limited) and 5xx are transient.
  def transient_error?(error)
    status = error.status
    return true if status.nil?

    status == 429 || status >= 500
  end
end
