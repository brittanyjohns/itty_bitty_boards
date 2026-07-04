require "rails_helper"

RSpec.describe MissionControl::DownloadLeadMetrics do
  describe ".call" do
    it "counts leads across time windows and all-time" do
      create(:download_lead, created_at: 2.hours.ago)
      create(:download_lead, created_at: 3.days.ago)
      create(:download_lead, created_at: 20.days.ago)
      create(:download_lead, created_at: 90.days.ago)

      metrics = described_class.call

      expect(metrics[:leads_today]).to eq(1)
      expect(metrics[:leads_7d]).to eq(2)
      expect(metrics[:leads_30d]).to eq(3)
      expect(metrics[:total_leads]).to eq(4)
    end

    it "counts unique emails (deduping repeat downloaders) over 7d" do
      create(:download_lead, email: "repeat@example.com", created_at: 1.day.ago)
      create(:download_lead, email: "repeat@example.com", created_at: 2.days.ago)
      create(:download_lead, email: "solo@example.com", created_at: 1.day.ago)

      expect(described_class.call[:unique_emails_7d]).to eq(2)
    end

    it "breaks leads down by Mailchimp sync status" do
      create(:download_lead, mailchimp_status: DownloadLead::MAILCHIMP_PENDING)
      create(:download_lead, mailchimp_status: DownloadLead::MAILCHIMP_SYNCED)
      create(:download_lead, mailchimp_status: DownloadLead::MAILCHIMP_SYNCED)
      create(:download_lead, mailchimp_status: DownloadLead::MAILCHIMP_FAILED)

      metrics = described_class.call

      expect(metrics[:mailchimp_pending]).to eq(1)
      expect(metrics[:mailchimp_synced]).to eq(2)
      expect(metrics[:mailchimp_failed]).to eq(1)
    end

    it "groups leads by source, busiest first" do
      create_list(:download_lead, 2, source: "free_board_landing")
      create(:download_lead, source: "etsy")

      expect(described_class.call[:leads_by_source]).to eq(
        "free_board_landing" => 2,
        "etsy" => 1,
      )
    end
  end
end
