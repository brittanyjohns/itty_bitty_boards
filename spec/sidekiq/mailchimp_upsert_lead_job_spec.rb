require "rails_helper"

RSpec.describe MailchimpUpsertLeadJob, type: :job do
  subject(:job) { described_class.new }

  let(:lead) { create(:download_lead, email: "lead@example.com", name: "Jamie") }
  let(:mailchimp) { instance_double(MailchimpService) }

  before { allow(MailchimpService).to receive(:new).and_return(mailchimp) }

  describe "#perform" do
    it "upserts the lead to Mailchimp with the BoardDownloadLead tag and marks it synced" do
      expect(mailchimp).to receive(:record_lead).with(
        email: "lead@example.com",
        name: "Jamie",
        tags: ["BoardDownloadLead"],
      )

      job.perform(lead.id)

      expect(lead.reload.mailchimp_status).to eq("synced")
    end

    it "uses the ClassroomKitLead tag for a classroom_kit source lead" do
      classroom_lead = create(:download_lead, email: "teacher@example.com", name: "Sam", source: "classroom_kit")

      expect(mailchimp).to receive(:record_lead).with(
        email: "teacher@example.com",
        name: "Sam",
        tags: ["ClassroomKitLead"],
      )

      job.perform(classroom_lead.id)

      expect(classroom_lead.reload.mailchimp_status).to eq("synced")
    end

    it "uses the ctg-2026 tag for a ctg source lead" do
      ctg_lead = create(:download_lead, email: "booth@example.com", name: "Alex", source: "ctg")

      expect(mailchimp).to receive(:record_lead).with(
        email: "booth@example.com",
        name: "Alex",
        tags: ["ctg-2026"],
      )

      job.perform(ctg_lead.id)

      expect(ctg_lead.reload.mailchimp_status).to eq("synced")
    end

    # Booth capture is email-only — no name, no address. record_lead must still
    # be called (and succeed) with a nil name, since the audience has no
    # required merge fields a bare-email lead couldn't supply.
    it "syncs a bare-email lead that has no name" do
      bare_lead = create(:download_lead, email: "bare@example.com", name: nil, source: "ctg")

      expect(mailchimp).to receive(:record_lead).with(
        email: "bare@example.com",
        name: nil,
        tags: ["ctg-2026"],
      )

      job.perform(bare_lead.id)

      expect(bare_lead.reload.mailchimp_status).to eq("synced")
    end

    it "marks the lead failed and re-raises on a transient (5xx) Mailchimp API error" do
      allow(mailchimp).to receive(:record_lead)
        .and_raise(MailchimpMarketing::ApiError.new(status: 500, message: "boom"))

      expect { job.perform(lead.id) }.to raise_error(MailchimpMarketing::ApiError)
      expect(lead.reload.mailchimp_status).to eq("failed")
    end

    it "re-raises on a rate-limit (429) so Sidekiq retries" do
      allow(mailchimp).to receive(:record_lead)
        .and_raise(MailchimpMarketing::ApiError.new(status: 429, message: "slow down"))

      expect { job.perform(lead.id) }.to raise_error(MailchimpMarketing::ApiError)
      expect(lead.reload.mailchimp_status).to eq("failed")
    end

    it "marks the lead failed but does NOT re-raise on a permanent 4xx (e.g. required merge field)" do
      allow(mailchimp).to receive(:record_lead)
        .and_raise(MailchimpMarketing::ApiError.new(
          status: 400,
          detail: "Your merge fields were invalid.",
        ))

      expect { job.perform(lead.id) }.not_to raise_error
      expect(lead.reload.mailchimp_status).to eq("failed")
    end

    it "no-ops for an unknown lead id" do
      expect(mailchimp).not_to receive(:record_lead)
      expect { job.perform(-1) }.not_to raise_error
    end
  end
end
