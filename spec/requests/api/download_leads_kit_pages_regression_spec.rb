require "rails_helper"

# /classroom and /ctg are printed on QR codes and live in campaign emails, and
# both post to POST /api/download_leads. Kit landing pages reuse the same table
# and the same Mailchimp job, so this pins the pre-existing contract: nothing
# about that endpoint, its response shape, its sources, or its tags may change
# because kit pages exist.
RSpec.describe "API download_leads — unchanged by kit pages", type: :request do
  before { MailchimpUpsertLeadJob.jobs.clear }

  # A kit page whose slug could collide with the legacy funnels if anything
  # ever started resolving tags by slug rather than by the kit_ prefix.
  let!(:decoy_page) do
    create(:kit_page, slug: "classroom-kit", mailchimp_tag: "ShouldNeverBeUsedHere")
  end

  describe "the endpoint itself" do
    it "still creates a lead and returns 201 { success: true } with no auth" do
      expect {
        post "/api/download_leads",
             params: { download_lead: { email: "teacher@example.com", name: "Sam", source: "classroom_kit" } }
      }.to change(DownloadLead, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)).to eq("success" => true)
      expect(DownloadLead.last.source).to eq("classroom_kit")
    end

    it "still returns 422 { success: false, errors: [...] } for a bad email" do
      post "/api/download_leads", params: { download_lead: { email: "nope" } }

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(false)
      expect(body["errors"]).to be_present
    end

    it "still defaults a source-less lead to free_download" do
      post "/api/download_leads", params: { download_lead: { email: "anon@example.com" } }

      expect(DownloadLead.last.source).to eq(DownloadLead::DEFAULT_SOURCE)
    end

    it "still hands the lead straight to MailchimpUpsertLeadJob" do
      post "/api/download_leads", params: { download_lead: { email: "ctg@example.com", source: "ctg" } }

      expect(MailchimpUpsertLeadJob.jobs.size).to eq(1)
      expect(MailchimpUpsertLeadJob.jobs.first["args"]).to eq([DownloadLead.last.id])
    end
  end

  describe "the tags the legacy funnels resolve to" do
    let(:mailchimp) { instance_double(MailchimpService) }

    before { allow(MailchimpService).to receive(:new).and_return(mailchimp) }

    {
      "classroom_kit" => "ClassroomKitLead",
      "ctg" => "ctg-2026",
      "playground_nomination" => "PlaygroundNomination",
      "free_download" => "BoardDownloadLead",
    }.each do |source, tag|
      it "still tags a #{source} lead #{tag}" do
        lead = create(:download_lead, source: source, data: { "marketing_opt_in" => "true" })

        expect(mailchimp).to receive(:record_lead).with(hash_including(tags: [tag]))

        MailchimpUpsertLeadJob.new.perform(lead.id)
      end
    end

    it "does not consult a KitPage for a legacy source, even one whose slug looks alike" do
      lead = create(:download_lead, source: "classroom_kit")
      allow(mailchimp).to receive(:record_lead)

      expect(KitPage).not_to receive(:for_lead_source)

      MailchimpUpsertLeadJob.new.perform(lead.id)
    end
  end
end
