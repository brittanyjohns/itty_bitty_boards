require "rails_helper"

# GET /api/kit_pages/:slug and POST /api/kit_pages/:slug/download are both
# PUBLIC. The read must never carry a file URL; the URL is revealed only after
# an email is captured as a DownloadLead.
RSpec.describe "API kit_pages", type: :request do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "At school") }

  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
  end

  def attach_all_variants
    printable.attach_pdf!(
      filename: "at-school.color.pdf", bytes: "%PDF-1.5 colour",
      variant: BoardPrintable::VARIANT_COLOR,
    )
    printable.attach_pdf!(
      filename: "at-school.low-ink.pdf", bytes: "%PDF-1.5 low ink",
      variant: BoardPrintable::VARIANT_LOW_INK,
    )
  end

  let(:content) do
    {
      "items" => [{ "title" => "Core word poster", "description" => "One page, 36 words." }],
      "closing" => { "heading" => "Make it personal", "body" => "Build your own.", "cta_path" => "/sign-up" },
    }
  end

  let(:page) do
    create(
      :kit_page,
      slug: "at-school", title: "The at-school kit", eyebrow: "Free classroom kit",
      subhead: "Everything for the first week.", content: content,
      cta_label: "Start free", cta_path: "/sign-up",
      board_printable: printable, printable_variant: BoardPrintable::VARIANT_COLOR,
    )
  end

  before { MailchimpUpsertLeadJob.jobs.clear }

  describe "GET /api/kit_pages/:slug" do
    it "returns the page for an anonymous visitor, with no file URL in the body" do
      attach_all_variants

      get "/api/kit_pages/#{page.slug}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["slug"]).to eq("at-school")
      expect(body["title"]).to eq("The at-school kit")
      expect(body["eyebrow"]).to eq("Free classroom kit")
      expect(body["subhead"]).to eq("Everything for the first week.")
      expect(body["content"]).to eq(content)
      expect(body["cta_label"]).to eq("Start free")
      expect(body["cta_path"]).to eq("/sign-up")
      expect(body["downloadable"]).to eq(true)

      # The whole point of the gate: nothing in the read response is a link to
      # the PDF.
      expect(response.body).not_to include(".pdf")
      expect(body.keys).not_to include("files")
    end

    it "reports downloadable: false when the printable has no files yet" do
      get "/api/kit_pages/#{page.slug}"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["downloadable"]).to eq(false)
    end

    it "reports downloadable: false when no printable is picked" do
      draft = create(:kit_page, slug: "no-printable", board_printable: nil)

      get "/api/kit_pages/#{draft.slug}"

      expect(JSON.parse(response.body)["downloadable"]).to eq(false)
    end

    it "404s an unpublished page" do
      page.update!(published: false)

      get "/api/kit_pages/#{page.slug}"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq("error" => "kit_page_not_found")
    end

    it "404s an unknown slug" do
      get "/api/kit_pages/nope"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq("error" => "kit_page_not_found")
    end
  end

  describe "POST /api/kit_pages/:slug/download" do
    it "captures the lead, enqueues the Mailchimp sync, and returns the files" do
      attach_all_variants

      expect {
        post "/api/kit_pages/#{page.slug}/download",
             params: { email: "teacher@example.com", name: "Sam", data: { utm_source: "qr" } }
      }.to change(DownloadLead, :count).by(1)

      expect(response).to have_http_status(:ok)
      files = JSON.parse(response.body)["files"]
      expect(files.map { |f| f["variant"] }).to eq(["color"])
      expect(files.first["filename"]).to eq("at-school.color.pdf")
      expect(files.first["url"]).to be_present

      lead = DownloadLead.last
      expect(lead.email).to eq("teacher@example.com")
      expect(lead.name).to eq("Sam")
      expect(lead.source).to eq("kit_at-school")
      expect(lead.data).to eq("utm_source" => "qr", "kit_slug" => "at-school")

      expect(MailchimpUpsertLeadJob.jobs.size).to eq(1)
      expect(MailchimpUpsertLeadJob.jobs.first["args"]).to eq([lead.id])
    end

    it "works without auth headers and without a data payload" do
      attach_all_variants

      post "/api/kit_pages/#{page.slug}/download", params: { email: "bare@example.com" }

      expect(response).to have_http_status(:ok)
      expect(DownloadLead.last.data).to eq("kit_slug" => "at-school")
    end

    it "returns only the chosen variant when it is present" do
      attach_all_variants
      page.update!(printable_variant: BoardPrintable::VARIANT_LOW_INK)

      post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@example.com" }

      files = JSON.parse(response.body)["files"]
      expect(files.map { |f| f["variant"] }).to eq(["low_ink"])
    end

    # A single-board printable carries one "full" document, so a page asking
    # for "color" must still hand something over rather than nothing.
    it "falls back to every PDF when the chosen variant is absent" do
      printable.attach_pdf!(
        filename: "at-school.pdf", bytes: "%PDF-1.5 everything",
        variant: BoardPrintable::VARIANT_FULL,
      )

      post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@example.com" }

      files = JSON.parse(response.body)["files"]
      expect(files.map { |f| f["variant"] }).to eq(["full"])
    end

    it "422s with errors for a blank email and captures nothing" do
      attach_all_variants

      expect {
        post "/api/kit_pages/#{page.slug}/download", params: { name: "No email" }
      }.not_to change(DownloadLead, :count)

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(false)
      expect(body["errors"]).to be_present
      expect(MailchimpUpsertLeadJob.jobs.size).to eq(0)
    end

    it "422s for a malformed email" do
      attach_all_variants

      expect {
        post "/api/kit_pages/#{page.slug}/download", params: { email: "nope" }
      }.not_to change(DownloadLead, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "422s not_available when the page has no printable" do
      draft = create(:kit_page, slug: "no-printable", board_printable: nil)

      expect {
        post "/api/kit_pages/#{draft.slug}/download", params: { email: "teacher@example.com" }
      }.not_to change(DownloadLead, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq("error" => "not_available")
    end

    it "422s not_available when the printable is still generating" do
      attach_all_variants
      printable.update!(status: "generating")

      post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@example.com" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq("error" => "not_available")
    end

    it "404s an unpublished page rather than capturing the lead" do
      attach_all_variants
      page.update!(published: false)

      expect {
        post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@example.com" }
      }.not_to change(DownloadLead, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
