require "rails_helper"

# POST /api/download_leads is PUBLIC (no auth). It captures an anonymous
# visitor's email as a DownloadLead and enqueues the Mailchimp sync job.
RSpec.describe "API download_leads", type: :request do
  before { MailchimpUpsertLeadJob.jobs.clear }

  describe "POST /api/download_leads" do
    context "with a valid email" do
      let(:board) { create(:board) }

      let(:params) do
        {
          download_lead: {
            email: "newlead@example.com",
            name: "Sam",
            board_id: board.id,
            source: "free_download",
            data: { utm: "etsy" },
          },
        }
      end

      it "creates the lead, returns 201, and enqueues the Mailchimp job" do
        expect {
          post "/api/download_leads", params: params
        }.to change(DownloadLead, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(JSON.parse(response.body)).to eq("success" => true)

        lead = DownloadLead.last
        expect(lead.email).to eq("newlead@example.com")
        expect(lead.name).to eq("Sam")
        expect(lead.board_id).to eq(board.id)
        expect(lead.source).to eq("free_download")
        expect(lead.data).to eq("utm" => "etsy")

        expect(MailchimpUpsertLeadJob.jobs.size).to eq(1)
        expect(MailchimpUpsertLeadJob.jobs.first["args"]).to eq([lead.id])
      end

      it "works without auth headers" do
        post "/api/download_leads", params: params
        expect(response).to have_http_status(:created)
      end
    end

    # The CTG booth capture is email-only (no name, no board) and carries the
    # QR/email UTMs onto the lead's data for campaign attribution.
    context "with a ctg booth capture (email only)" do
      let(:params) do
        {
          download_lead: {
            email: "booth@example.com",
            source: "ctg",
            data: { utm_campaign: "ctg-2026", utm_source: "qr", utm_content: "booth" },
          },
        }
      end

      it "creates a ctg-sourced lead with no name and enqueues the Mailchimp job" do
        expect {
          post "/api/download_leads", params: params
        }.to change(DownloadLead, :count).by(1)

        expect(response).to have_http_status(:created)

        lead = DownloadLead.last
        expect(lead.email).to eq("booth@example.com")
        expect(lead.name).to be_blank
        expect(lead.board_id).to be_nil
        expect(lead.source).to eq("ctg")
        expect(lead.data).to eq(
          "utm_campaign" => "ctg-2026", "utm_source" => "qr", "utm_content" => "booth"
        )

        expect(MailchimpUpsertLeadJob.jobs.size).to eq(1)
        expect(MailchimpUpsertLeadJob.jobs.first["args"]).to eq([lead.id])
      end

      it "maps the ctg source to the ctg-2026 Mailchimp tag" do
        post "/api/download_leads", params: params

        expect(MailchimpUpsertLeadJob::SOURCE_TAGS.fetch(DownloadLead.last.source))
          .to eq("ctg-2026")
      end
    end

    context "with an invalid / missing email" do
      it "returns 422 with errors and creates no lead (missing email)" do
        expect {
          post "/api/download_leads", params: { download_lead: { name: "NoEmail" } }
        }.not_to change(DownloadLead, :count)

        expect(response).to have_http_status(:unprocessable_content)
        body = JSON.parse(response.body)
        expect(body["success"]).to eq(false)
        expect(body["errors"]).to be_present

        expect(MailchimpUpsertLeadJob.jobs.size).to eq(0)
      end

      it "returns 422 for a malformed email" do
        expect {
          post "/api/download_leads", params: { download_lead: { email: "nope" } }
        }.not_to change(DownloadLead, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(MailchimpUpsertLeadJob.jobs.size).to eq(0)
      end
    end
  end
end
