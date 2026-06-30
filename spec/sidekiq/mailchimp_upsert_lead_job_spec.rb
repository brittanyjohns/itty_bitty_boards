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

    it "marks the lead failed and re-raises on a Mailchimp API error" do
      allow(mailchimp).to receive(:record_lead)
        .and_raise(MailchimpMarketing::ApiError.new(status: 500, message: "boom"))

      expect { job.perform(lead.id) }.to raise_error(MailchimpMarketing::ApiError)
      expect(lead.reload.mailchimp_status).to eq("failed")
    end

    it "no-ops for an unknown lead id" do
      expect(mailchimp).not_to receive(:record_lead)
      expect { job.perform(-1) }.not_to raise_error
    end
  end
end
