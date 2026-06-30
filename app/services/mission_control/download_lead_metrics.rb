module MissionControl
  # Lead-gen funnel for the anonymous free-board downloads (DownloadLead).
  # Surfaces volume over time plus Mailchimp sync health — a rising "failed"
  # count means captured leads aren't reaching the Mailchimp audience.
  class DownloadLeadMetrics
    def self.call = new.call

    def call
      {
        leads_today:         DownloadLead.where(created_at: today).count,
        leads_7d:            DownloadLead.where(created_at: 7.days.ago..).count,
        leads_30d:           DownloadLead.where(created_at: 30.days.ago..).count,
        total_leads:         DownloadLead.count,

        # Distinct people (the same email may grab several boards).
        unique_emails_7d:    DownloadLead.where(created_at: 7.days.ago..).distinct.count(:email),

        # Mailchimp sync health.
        mailchimp_pending:   DownloadLead.mailchimp_pending.count,
        mailchimp_synced:    DownloadLead.mailchimp_synced.count,
        mailchimp_failed:    DownloadLead.mailchimp_failed.count,

        # Where leads came from, busiest first.
        leads_by_source:     leads_by_source,
      }
    end

    private

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end

    def leads_by_source
      DownloadLead.group(:source).count.sort_by { |_source, count| -count }.to_h
    end
  end
end
