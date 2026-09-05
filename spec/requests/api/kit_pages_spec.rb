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
    context "the mockup images" do
      it "returns the curated gallery, in landing-page order" do
        attach_all_variants
        printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_ON_PAPER)
        printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)

        get "/api/kit_pages/#{page.slug}"

        body = JSON.parse(response.body)
        expect(body["images"].map { |image| image["variant"] })
          .to eq([BoardPrintable::IMAGE_HERO, BoardPrintable::IMAGE_ON_PAPER])
        expect(body["images"].map { |image| image["url"] }).to all(be_present)
      end

      it "returns an empty list for a page with no printable" do
        page.update!(board_printable: nil)

        get "/api/kit_pages/#{page.slug}"

        expect(JSON.parse(response.body)["images"]).to eq([])
      end

      it "reveals a mockup but still no PDF, which stays behind the email" do
        attach_all_variants
        printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)

        get "/api/kit_pages/#{page.slug}"

        expect(JSON.parse(response.body)["images"]).to be_present
        expect(response.body).not_to include(".pdf")
      end
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
      # The URL the Download button actually uses. `url` previews (the CDN sends
      # no Content-Disposition); this one carries `attachment`, so the browser
      # saves the PDF instead of opening a viewer tab.
      expect(files.first["download_url"]).to be_present

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

  # An admin looking at a draft on the real frontend. The token is the ONLY way
  # past the published scope — being signed in as an admin is not, because
  # /kit/:slug is deliberately anonymous.
  describe "draft preview" do
    let(:draft) do
      create(:kit_page, slug: "draft-kit", title: "Draft kit", published: false,
                        board_printable: printable, printable_variant: BoardPrintable::VARIANT_COLOR)
    end
    let(:token) { draft.preview_token }

    before { attach_all_variants }

    it "serves the unpublished page with a valid token, flagged as a preview" do
      get "/api/kit_pages/#{draft.slug}", params: { preview: token }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["title"]).to eq("Draft kit")
      expect(body["preview"]).to eq(true)
    end

    it "still 404s the draft without a token" do
      get "/api/kit_pages/#{draft.slug}"

      expect(response).to have_http_status(:not_found)
    end

    # A wrong guess must not become a way to probe for drafts.
    it "404s a garbage token exactly like a missing page" do
      get "/api/kit_pages/#{draft.slug}", params: { preview: "not-a-token" }

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq("error" => "kit_page_not_found")
    end

    it "refuses a token minted for a different page" do
      other = create(:kit_page, slug: "other-draft", published: false)

      get "/api/kit_pages/#{draft.slug}", params: { preview: other.preview_token }

      expect(response).to have_http_status(:not_found)
    end

    it "refuses an expired token" do
      expired = draft.preview_token

      travel_to(KitPage::PREVIEW_TOKEN_TTL.from_now + 1.minute) do
        get "/api/kit_pages/#{draft.slug}", params: { preview: expired }
      end

      expect(response).to have_http_status(:not_found)
    end

    it "hands over the files without writing a lead or touching Mailchimp" do
      expect {
        post "/api/kit_pages/#{draft.slug}/download",
             params: { email: "admin@example.com", preview: token }
      }.to not_change(DownloadLead, :count).and not_change { MailchimpUpsertLeadJob.jobs.size }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["files"]).to be_present
    end

    it "will not download the draft without a token" do
      expect {
        post "/api/kit_pages/#{draft.slug}/download", params: { email: "teacher@example.com" }
      }.not_to change(DownloadLead, :count)

      expect(response).to have_http_status(:not_found)
    end

    # A visitor who was forwarded a preview link to a page that has since gone
    # live is an ordinary visitor, and must still be counted as a lead.
    it "counts a real lead when the token is passed to a published page" do
      draft.update!(published: true)

      expect {
        post "/api/kit_pages/#{draft.slug}/download",
             params: { email: "teacher@example.com", preview: token }
      }.to change(DownloadLead, :count).by(1)

      expect(JSON.parse(response.body)["files"]).to be_present
    end

    it "does not flag a published page as a preview" do
      draft.update!(published: true)

      get "/api/kit_pages/#{draft.slug}", params: { preview: token }

      expect(JSON.parse(response.body)).not_to have_key("preview")
    end
  end

  # A page whose download is uploaded straight onto it, rather than generated
  # as a board printable. The public contract is identical — same `files`
  # shape, same email gate, same "no file URL on the read".
  describe "an uploaded-document page" do
    before do
      attach_all_variants
      page.attach_document!(io: StringIO.new("%PDF handout"), filename: "handout.pdf", label: "Parent handout")
      page.attach_preview_image!(bytes: "PNG", page: 1)
    end

    it "shows the rendered pages and still no file URL" do
      get "/api/kit_pages/#{page.slug}"

      body = JSON.parse(response.body)
      expect(body["downloadable"]).to eq(true)
      expect(body["images"].map { |image| image["variant"] }).to eq(["page_1"])
      expect(response.body).not_to include("handout.pdf")
      expect(response.body).not_to include(".pdf")
    end

    it "hands over the uploaded document, not the printable's PDFs" do
      expect {
        post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@example.com" }
      }.to change(DownloadLead, :count).by(1)

      files = JSON.parse(response.body)["files"]
      expect(files.map { |file| file["filename"] }).to eq(["handout.pdf"])
      expect(files.first["variant"]).to eq("Parent handout")
      expect(files.first["url"]).to be_present
      expect(files.first).to have_key("download_url")
      expect(DownloadLead.last.source).to eq("kit_at-school")
    end

    it "enqueues the Mailchimp upsert like any other kit lead" do
      expect {
        post "/api/kit_pages/#{page.slug}/download",
             params: { email: "teacher@example.com", data: { consent: true } }
      }.to change { MailchimpUpsertLeadJob.jobs.size }.by(1)
    end

    # A picture may be marketing (public) or part of what the email buys
    # (gated). The public read must never carry the second kind.
    describe "pages held back until the email" do
      let(:document) { page.ordered_documents.first }

      before do
        page.attach_preview_image!(bytes: "PNG", page: 2, document_id: document.blob_id)
        page.attach_preview_image!(bytes: "PNG", page: 3, document_id: document.blob_id)
        page.update!(preview_settings: {
          KitPage.preview_setting_key(document.blob_id, 1) => "public",
          KitPage.preview_setting_key(document.blob_id, 2) => "gated",
          KitPage.preview_setting_key(document.blob_id, 3) => "hidden",
        })
      end

      it "publishes only the public pages" do
        get "/api/kit_pages/#{page.slug}"

        expect(JSON.parse(response.body)["images"].map { |i| i["page"] }).to eq([1])
      end

      it "hands over the public and the gated pages after the email, never the hidden one" do
        post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@example.com" }

        expect(JSON.parse(response.body)["images"].map { |i| i["page"] }).to eq([1, 2])
      end

      it "shows no pictures at all when every page is held back" do
        page.update!(preview_settings: page.preview_settings.merge(
          KitPage.preview_setting_key(document.blob_id, 1) => "gated",
        ))

        get "/api/kit_pages/#{page.slug}"
        expect(JSON.parse(response.body)["images"]).to eq([])

        post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@example.com" }
        expect(JSON.parse(response.body)["images"].map { |i| i["page"] }).to eq([1, 2])
      end
    end
  end

  # A page whose product is an editable Canva design rather than a PDF. Same
  # gate, same lead, same `kit_<slug>` source — only the thing handed over
  # differs.
  describe "a Canva-template page" do
    let(:link) { "https://www.canva.com/design/DAGabc123/xyz/view" }

    let(:template_page) do
      create(
        :kit_page,
        slug: "myspeak-id-card", title: "MySpeak ID card",
        canva_templates: [
          { "label" => "Lanyard card", "url" => link, "description" => "Two per page" },
        ],
      )
    end

    it "advertises the templates on the public read without their links" do
      get "/api/kit_pages/#{template_page.slug}"

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body["templates"]).to eq(
        [{ "label" => "Lanyard card", "description" => "Two per page" }]
      )
      # The whole invariant, asserted against the raw body rather than a key:
      # the link may not appear anywhere in the anonymous payload.
      expect(response.body).not_to include("canva.com")
    end

    # `downloadable?` keeps its narrow meaning — there is no PDF — and the gate
    # opens anyway, because the page still has something to hand over.
    it "reports downloadable: false yet still opens the gate" do
      get "/api/kit_pages/#{template_page.slug}"

      expect(JSON.parse(response.body)["downloadable"]).to eq(false)

      expect {
        post "/api/kit_pages/#{template_page.slug}/download", params: { email: "teacher@school.org" }
      }.to change(DownloadLead, :count).by(1)

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body["templates"]).to eq(
        [{ "label" => "Lanyard card", "description" => "Two per page", "url" => link }]
      )
      # Present but empty, so a frontend that predates templates renders its
      # existing "nothing to download" dead end rather than throwing.
      expect(body["files"]).to eq([])

      lead = DownloadLead.last
      expect(lead.source).to eq("kit_myspeak-id-card")
      expect(MailchimpUpsertLeadJob.jobs.size).to eq(1)
    end

    it "hands over the PDF and the templates together when the page has both" do
      attach_all_variants
      page.update!(canva_templates: [{ "label" => "Lanyard card", "url" => link }])

      post "/api/kit_pages/#{page.slug}/download", params: { email: "teacher@school.org" }

      body = JSON.parse(response.body)
      expect(body["files"].size).to eq(1)
      expect(body["templates"].sole["url"]).to eq(link)
    end

    it "answers not_available only when there is neither a PDF nor a template" do
      empty = create(:kit_page, slug: "nothing-here")

      expect {
        post "/api/kit_pages/#{empty.slug}/download", params: { email: "teacher@school.org" }
      }.not_to change(DownloadLead, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("not_available")
    end

    it "hands a draft's templates to a preview token without writing a lead" do
      draft = create(
        :kit_page, slug: "draft-card", published: false,
        canva_templates: [{ "label" => "Card", "url" => link }],
      )

      expect {
        post "/api/kit_pages/#{draft.slug}/download",
             params: { email: "admin@speakanyway.com", preview: draft.preview_token }
      }.not_to change(DownloadLead, :count)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["templates"].sole["url"]).to eq(link)
      expect(MailchimpUpsertLeadJob.jobs).to be_empty
    end
  end
end
