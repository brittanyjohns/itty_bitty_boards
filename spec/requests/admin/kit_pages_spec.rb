require "rails_helper"

RSpec.describe "Admin kit pages", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "At school") }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 6)
      .tap { |p| p.attach_pdf!(filename: "at-school.color.pdf", bytes: "%PDF c", variant: "color") }
  end

  def base_params(overrides = {})
    {
      slug: "at-school",
      title: "The at-school kit",
      eyebrow: "Free classroom kit",
      subhead: "Everything for the first week.",
      board_printable_id: printable.id,
      printable_variant: "color",
      cta_label: "Start free",
      cta_path: "/sign-up",
      content: { items: [{ title: "Poster", description: "One page." }] }.to_json,
    }.merge(overrides)
  end

  describe "authorization" do
    it "redirects a signed-out visitor away from the index" do
      get admin_dashboard_kit_pages_path
      expect(response).to have_http_status(:redirect)
    end

    it "redirects a non-admin away from the index" do
      sign_in owner
      get admin_dashboard_kit_pages_path
      expect(response).to redirect_to(root_path)
    end

    it "refuses a non-admin's create" do
      sign_in owner
      expect { post admin_dashboard_kit_pages_path, params: base_params }
        .not_to change(KitPage, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  context "as an admin" do
    before { sign_in admin }

    describe "GET /admin/kit_pages" do
      it "lists the pages with their slug, tag and status" do
        create(:kit_page, slug: "at-school", title: "The at-school kit", published: false)

        get admin_dashboard_kit_pages_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("The at-school kit", "/kit/at-school", "AtSchoolLead", "draft")
      end

      it "renders an empty state" do
        get admin_dashboard_kit_pages_path
        expect(response.body).to include("No kit pages yet")
      end
    end

    describe "GET /admin/kit_pages/new" do
      it "offers only complete printables that carry a PDF" do
        printable
        no_pdf = BoardPrintable.create!(
          board: create(:board, user: owner, name: "Nothing attached"),
          status: "complete", board_ids: [board.id],
        )
        pending = BoardPrintable.create!(
          board: create(:board, user: owner, name: "Still cooking"),
          status: "generating", board_ids: [board.id],
        )

        get new_admin_dashboard_kit_page_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("At school")
        expect(response.body).not_to include("Nothing attached")
        expect(response.body).not_to include("Still cooking")
        expect(no_pdf.pdf_files).to be_empty
        expect(pending).not_to be_complete
      end
    end

    describe "POST /admin/kit_pages" do
      it "creates the page from flat params" do
        expect { post admin_dashboard_kit_pages_path, params: base_params(published: "1") }
          .to change(KitPage, :count).by(1)

        page = KitPage.last
        expect(page.slug).to eq("at-school")
        expect(page.title).to eq("The at-school kit")
        expect(page.eyebrow).to eq("Free classroom kit")
        expect(page.board_printable).to eq(printable)
        expect(page.printable_variant).to eq("color")
        expect(page.content["items"].first["title"]).to eq("Poster")
        expect(page).to be_published
        expect(response).to redirect_to(edit_admin_dashboard_kit_page_path(page))
      end

      it "creates an unpublished draft when the box isn't ticked" do
        post admin_dashboard_kit_pages_path, params: base_params

        expect(KitPage.last).not_to be_published
      end

      it "re-renders with an error and saves nothing on a bad slug" do
        expect { post admin_dashboard_kit_pages_path, params: base_params(slug: "At School") }
          .not_to change(KitPage, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Slug")
      end

      it "re-renders with a parse error and keeps what was typed when the content isn't JSON" do
        expect { post admin_dashboard_kit_pages_path, params: base_params(content: "{ nope") }
          .not_to change(KitPage, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("isn&#39;t valid JSON").or include("isn't valid JSON")
        expect(response.body).to include("{ nope")
      end

      it "rejects a content blob that isn't a JSON object" do
        expect { post admin_dashboard_kit_pages_path, params: base_params(content: "[1, 2]") }
          .not_to change(KitPage, :count)

        expect(response.body).to include("must be a JSON object")
      end

      it "treats a blank content box as an empty object" do
        post admin_dashboard_kit_pages_path, params: base_params(content: "")

        expect(KitPage.last.content).to eq({})
      end
    end

    # Giving away a printable that is sold on Etsy is a two-step on purpose.
    describe "the Etsy give-away guard" do
      let(:sold) do
        BoardPrintable.create!(
          board: board, status: "complete", board_ids: [board.id],
          etsy_published_at: 1.week.ago, etsy_listing_id: 4_242_424_242,
        ).tap { |p| p.attach_pdf!(filename: "sold.color.pdf", bytes: "%PDF s", variant: "color") }
      end

      it "blocks the save and explains why, with no record written" do
        expect { post admin_dashboard_kit_pages_path, params: base_params(board_printable_id: sold.id) }
          .not_to change(KitPage, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("published on Etsy")
        expect(response.body).to include("Give this away for free anyway")
      end

      it "saves and stamps the override when it is explicitly confirmed" do
        post admin_dashboard_kit_pages_path,
             params: base_params(board_printable_id: sold.id, etsy_override: "1")

        page = KitPage.last
        expect(page.board_printable).to eq(sold)
        expect(page.etsy_override_at).to be_present
        expect(page.etsy_override_by).to eq(admin)
      end

      it "does not ask again on an unrelated edit of the same page" do
        post admin_dashboard_kit_pages_path,
             params: base_params(board_printable_id: sold.id, etsy_override: "1")
        page = KitPage.last
        stamped_at = page.etsy_override_at

        patch admin_dashboard_kit_page_path(page),
              params: base_params(board_printable_id: sold.id, title: "Renamed")

        expect(response).to redirect_to(edit_admin_dashboard_kit_page_path(page))
        expect(page.reload.title).to eq("Renamed")
        expect(page.etsy_override_at).to be_within(1.second).of(stamped_at)
      end

      it "asks again when a DIFFERENT sold printable is swapped in" do
        post admin_dashboard_kit_pages_path,
             params: base_params(board_printable_id: sold.id, etsy_override: "1")
        page = KitPage.last

        other_sold = BoardPrintable.create!(
          board: create(:board, user: owner, name: "Also sold"), status: "complete",
          board_ids: [board.id], etsy_published_at: 1.day.ago, etsy_listing_id: 99,
        ).tap { |p| p.attach_pdf!(filename: "other.color.pdf", bytes: "%PDF o", variant: "color") }

        patch admin_dashboard_kit_page_path(page),
              params: base_params(board_printable_id: other_sold.id)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(page.reload.board_printable).to eq(sold)
      end

      it "clears a stale override when the page moves to an unprotected printable" do
        post admin_dashboard_kit_pages_path,
             params: base_params(board_printable_id: sold.id, etsy_override: "1")
        page = KitPage.last

        patch admin_dashboard_kit_page_path(page), params: base_params(board_printable_id: printable.id)

        expect(page.reload.board_printable).to eq(printable)
        expect(page.etsy_override_at).to be_nil
        expect(page.etsy_override_by).to be_nil
      end

      it "lets a waived printable through without the checkbox" do
        sold.update!(protection_waived_at: Time.current, protection_waived_by: admin)

        expect { post admin_dashboard_kit_pages_path, params: base_params(board_printable_id: sold.id) }
          .to change(KitPage, :count).by(1)
      end
    end

    describe "PATCH /admin/kit_pages/:id" do
      let!(:page) { create(:kit_page, slug: "at-school", title: "Old", published: false) }

      it "updates the page" do
        patch admin_dashboard_kit_page_path(page), params: base_params(title: "New title")

        expect(page.reload.title).to eq("New title")
        expect(response).to redirect_to(edit_admin_dashboard_kit_page_path(page))
      end

      it "blanks an emptied optional field rather than keeping the old value" do
        page.update!(eyebrow: "Old eyebrow")

        patch admin_dashboard_kit_page_path(page), params: base_params(eyebrow: "")

        expect(page.reload.eyebrow).to be_nil
      end
    end

    describe "publish / unpublish" do
      let!(:page) { create(:kit_page, slug: "at-school", published: false) }

      it "publishes" do
        post publish_admin_dashboard_kit_page_path(page)

        expect(page.reload).to be_published
        expect(response).to redirect_to(admin_dashboard_kit_pages_path)
      end

      it "unpublishes" do
        page.update!(published: true)

        post unpublish_admin_dashboard_kit_page_path(page)

        expect(page.reload).not_to be_published
      end
    end

    describe "POST /admin/kit_pages/autofill" do
      let(:ai_copy) do
        {
          "eyebrow" => "Free classroom kit",
          "title" => "The at-school communication kit",
          "subhead" => "Print it once and put it where the talking happens.",
          "items" => [{ "title" => "Snack time page", "description" => "One page, 36 words." }],
          "closing" => { "heading" => "Make it yours", "body" => "Build it in the app.",
                         "cta_label" => "Start free", "cta_path" => "/sign-up" },
        }.to_json
      end

      before do
        allow_any_instance_of(OpenAiClient).to receive(:create_chat)
          .and_return({ role: "assistant", content: ai_copy })
      end

      def blank_params(overrides = {})
        {
          slug: "", title: "", eyebrow: "", subhead: "", cta_label: "", cta_path: "", content: "",
          board_printable_id: printable.id, printable_variant: "color",
        }.merge(overrides)
      end

      it "fills every blank field from the printable" do
        post autofill_admin_dashboard_kit_pages_path, params: blank_params

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("The at-school communication kit")
        expect(response.body).to include("Free classroom kit")
        expect(response.body).to include("Snack time page")
      end

      it "derives the slug from the board name" do
        # A board name that isn't the form's own "at-school" placeholder, or the
        # assertion would pass without any derivation happening.
        other = create(:board, user: owner, name: "Playground talk")
        other_printable = BoardPrintable.create!(board: other, status: "complete", board_ids: [other.id], page_count: 2)
          .tap { |p| p.attach_pdf!(filename: "p.color.pdf", bytes: "%PDF", variant: "color") }

        post autofill_admin_dashboard_kit_pages_path,
             params: blank_params(board_printable_id: other_printable.id)

        expect(response.body).to include('value="playground-talk"')
      end

      it "uniquifies a derived slug that is already taken" do
        create(:kit_page, slug: "at-school")

        post autofill_admin_dashboard_kit_pages_path, params: blank_params

        expect(response.body).to include('value="at-school-2"')
      end

      it "never saves" do
        expect { post autofill_admin_dashboard_kit_pages_path, params: blank_params }
          .not_to change(KitPage, :count)
      end

      it "leaves a slug that was already typed alone" do
        post autofill_admin_dashboard_kit_pages_path, params: blank_params(slug: "my-own-slug")

        expect(response.body).to include("my-own-slug")
        expect(response.body).not_to include('value="at-school"')
      end

      it "leaves a title that was already typed alone" do
        post autofill_admin_dashboard_kit_pages_path, params: blank_params(title: "My own headline")

        expect(response.body).to include("My own headline")
        expect(response.body).not_to include("The at-school communication kit")
      end

      it "leaves a hand-written content blob alone" do
        typed = { "items" => [{ "title" => "Mine", "description" => "Hand written." }] }.to_json
        post autofill_admin_dashboard_kit_pages_path, params: blank_params(content: typed)

        expect(response.body).to include("Hand written.")
        expect(response.body).not_to include("Snack time page")
      end

      it "works with no printable chosen, from the slug alone" do
        post autofill_admin_dashboard_kit_pages_path, params: blank_params(slug: "at-the-dentist", board_printable_id: "")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("The at-school communication kit")
      end

      it "renders an error when there is nothing to work from" do
        post autofill_admin_dashboard_kit_pages_path, params: blank_params(board_printable_id: "")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("write the copy")
      end

      it "renders an error when the model answers with nonsense" do
        allow_any_instance_of(OpenAiClient).to receive(:create_chat)
          .and_return({ role: "assistant", content: "not json" })

        post autofill_admin_dashboard_kit_pages_path, params: blank_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("write the copy")
      end

      it "autofills an existing page without saving it" do
        page = create(:kit_page, slug: "at-school", title: "Old title", eyebrow: nil)

        post autofill_admin_dashboard_kit_page_path(page), params: blank_params(slug: "at-school", title: "Old title")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Old title")
        expect(response.body).to include("Free classroom kit")
        expect(page.reload.eyebrow).to be_nil
      end

      it "redirects when the page is gone" do
        post autofill_admin_dashboard_kit_page_path(id: 0), params: blank_params

        expect(response).to redirect_to(admin_dashboard_kit_pages_path)
      end

      # Request specs never run Turbo, so this assertion is the only thing that
      # catches the button silently becoming a no-op in a browser.
      it "renders the form with Turbo disabled" do
        post autofill_admin_dashboard_kit_pages_path, params: blank_params

        expect(response.body).to include('data-turbo="false"')
      end
    end

    describe "document upload" do
      let(:kit_page) { create(:kit_page, slug: "at-school", board_printable: printable) }

      def pdf_upload(filename: "handout.pdf", type: "application/pdf")
        Rack::Test::UploadedFile.new(file_fixture("sample.pdf"), type, original_filename: filename)
      end

      it "attaches the PDF and queues the previews" do
        expect {
          post upload_document_admin_dashboard_kit_page_path(kit_page),
               params: { document: pdf_upload, label: "Parent handout" }
        }.to change { RenderKitPreviewsJob.jobs.size }.by(1)

        expect(response).to redirect_to(edit_admin_dashboard_kit_page_path(kit_page))
        expect(kit_page.reload.ordered_documents.map { |f| f.filename.to_s }).to eq(["handout.pdf"])
        expect(kit_page.download_files.first[:variant]).to eq("Parent handout")
      end

      it "refuses a file that isn't a PDF" do
        post upload_document_admin_dashboard_kit_page_path(kit_page),
             params: { document: pdf_upload(filename: "shot.png", type: "image/png") }

        expect(flash[:alert]).to include("upload a PDF")
        expect(kit_page.reload.documents).to be_empty
      end

      it "refuses a file over the cap" do
        upload = pdf_upload
        allow_any_instance_of(ActionDispatch::Http::UploadedFile)
          .to receive(:size).and_return(KitPage::MAX_DOCUMENT_BYTES + 1)

        post upload_document_admin_dashboard_kit_page_path(kit_page), params: { document: upload }

        expect(flash[:alert]).to include("the cap is")
        expect(kit_page.reload.documents).to be_empty
      end

      it "refuses a submit with no file chosen" do
        post upload_document_admin_dashboard_kit_page_path(kit_page)

        expect(flash[:alert]).to eq("Choose a PDF to upload.")
        expect(kit_page.reload.documents).to be_empty
      end

      it "refuses one past the per-page limit" do
        KitPage::MAX_DOCUMENTS.times do |n|
          kit_page.attach_document!(io: StringIO.new("%PDF"), filename: "doc-#{n}.pdf")
        end

        post upload_document_admin_dashboard_kit_page_path(kit_page), params: { document: pdf_upload }

        expect(flash[:alert]).to include("already has #{KitPage::MAX_DOCUMENTS} documents")
        expect(kit_page.reload.ordered_documents.size).to eq(KitPage::MAX_DOCUMENTS)
      end

      it "removes a document and re-renders what is left" do
        document = kit_page.attach_document!(io: StringIO.new("%PDF"), filename: "handout.pdf")

        expect {
          delete remove_document_admin_dashboard_kit_page_path(kit_page, signed_id: document.signed_id)
        }.to change { RenderKitPreviewsJob.jobs.size }.by(1)

        expect(kit_page.reload.documents).to be_empty
      end

      it "will not remove a blob that isn't on this page" do
        other = create(:kit_page)
        stranger = other.attach_document!(io: StringIO.new("%PDF"), filename: "other.pdf")

        delete remove_document_admin_dashboard_kit_page_path(kit_page, signed_id: stranger.signed_id)

        expect(flash[:alert]).to include("isn't on this page")
        expect(other.reload.documents.size).to eq(1)
      end

      it "queues a re-render on request" do
        kit_page.attach_document!(io: StringIO.new("%PDF"), filename: "handout.pdf")
        allow(KitPages::DocumentPreviewRenderer).to receive(:available?).and_return(true)

        expect {
          post regenerate_previews_admin_dashboard_kit_page_path(kit_page)
        }.to change { RenderKitPreviewsJob.jobs.size }.by(1)
      end

      it "says so plainly when this host can't render previews" do
        allow(KitPages::DocumentPreviewRenderer).to receive(:available?).and_return(false)

        expect {
          post regenerate_previews_admin_dashboard_kit_page_path(kit_page)
        }.not_to change { RenderKitPreviewsJob.jobs.size }
        expect(flash[:alert]).to include("can't render PDF previews")
      end
    end

    describe "choosing which rendered pages show" do
      let(:kit_page) { create(:kit_page, slug: "at-school") }

      def render_pages!(pages: 3)
        document = kit_page.attach_document!(
          io: StringIO.new("%PDF handout"), filename: "handout.pdf", label: "Parent handout"
        )
        (1..pages).each { |n| kit_page.attach_preview_image!(bytes: "PNG", page: n, document_id: document.id) }
        document
      end

      it "saves the choices and says so" do
        document = render_pages!

        patch update_previews_admin_dashboard_kit_page_path(kit_page), params: {
          visibility: {
            KitPage.preview_setting_key(document.id, 1) => "public",
            KitPage.preview_setting_key(document.id, 2) => "gated",
            KitPage.preview_setting_key(document.id, 3) => "hidden",
          },
        }

        expect(response).to redirect_to(edit_admin_dashboard_kit_page_path(kit_page))
        expect(flash[:notice]).to include("which pages show")
        expect(kit_page.reload.public_preview_images.map { |i| i[:page] }).to eq([1])
        expect(kit_page.released_preview_images.map { |i| i[:page] }).to eq([1, 2])
      end

      # The same reasoning as remove_document's linear scan: a key from the form
      # must never reach a row this page doesn't own.
      it "ignores a key naming another page's document" do
        document = render_pages!
        other = create(:kit_page, slug: "elsewhere")
        other_doc = other.attach_document!(io: StringIO.new("%PDF x"), filename: "other.pdf")

        patch update_previews_admin_dashboard_kit_page_path(kit_page), params: {
          visibility: {
            KitPage.preview_setting_key(document.id, 1) => "public",
            KitPage.preview_setting_key(other_doc.id, 1) => "public",
          },
        }

        expect(kit_page.reload.preview_settings.keys)
          .to eq([KitPage.preview_setting_key(document.id, 1)])
      end

      it "ignores a visibility that isn't one of the three" do
        document = render_pages!

        patch update_previews_admin_dashboard_kit_page_path(kit_page), params: {
          visibility: { KitPage.preview_setting_key(document.id, 1) => "everywhere" },
        }

        expect(kit_page.reload.preview_settings).to eq({})
      end

      it "prunes a removed document's choices" do
        document = render_pages!
        kit_page.update!(preview_settings: { KitPage.preview_setting_key(document.id, 1) => "public" })

        delete remove_document_admin_dashboard_kit_page_path(
          kit_page, signed_id: kit_page.ordered_documents.first.signed_id
        )

        expect(kit_page.reload.preview_settings).to eq({})
      end

      it "offers three choices per rendered page on the edit screen" do
        document = render_pages!(pages: 2)

        get edit_admin_dashboard_kit_page_path(kit_page)

        expect(response.body).to include("Don&#39;t show").or include("Don't show")
        expect(response.body).to include("On the page")
        expect(response.body).to include("After the email")
        expect(response.body).to include("visibility[#{KitPage.preview_setting_key(document.id, 2)}]")
        # Nothing chosen yet, so the default it is actually showing is named.
        expect(response.body).to include("Nothing chosen yet")
      end

      it "warns when nothing at all is set to show on the page" do
        document = render_pages!(pages: 2)
        kit_page.update!(preview_settings: {
          KitPage.preview_setting_key(document.id, 1) => "gated",
          KitPage.preview_setting_key(document.id, 2) => "hidden",
        })

        get edit_admin_dashboard_kit_page_path(kit_page)

        expect(response.body).to include("visitors will see no pictures")
      end

      # The upload needs a saved row, so the New screen can only point at the
      # next step — but it must point, or it reads as "no way to upload here".
      it "tells the admin on the New screen where the upload box will be" do
        get new_admin_dashboard_kit_page_path

        expect(response.body).to include("Document")
        expect(response.body).to include("Create the page first")
      end

      it "tells the admin on the edit screen that the upload overrides the printable" do
        kit_page.attach_document!(io: StringIO.new("%PDF"), filename: "handout.pdf")

        get edit_admin_dashboard_kit_page_path(kit_page)

        expect(response.body).to include("handout.pdf")
        expect(response.body).to include("handing out an uploaded document instead")
      end
    end

    describe "the Preview link" do
      it "signs a draft's link so it actually opens" do
        draft = create(:kit_page, slug: "draft-kit", published: false)

        get edit_admin_dashboard_kit_page_path(draft)

        expect(response.body).to include("Preview draft")
        expect(response.body).to match(%r{/kit/draft-kit\?preview=})
      end

      # A live URL an admin might paste into a campaign must stay clean.
      it "leaves a published page's link untouched" do
        live = create(:kit_page, slug: "live-kit", published: true)

        get edit_admin_dashboard_kit_page_path(live)

        expect(response.body).to include("/kit/live-kit")
        expect(response.body).not_to include("preview=")
      end
    end

    describe "GET /admin/kit_pages/:id/edit" do
      it "renders the stored content as pretty JSON" do
        page = create(:kit_page, slug: "at-school", content: { "items" => [{ "title" => "Poster" }] })

        get edit_admin_dashboard_kit_page_path(page)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Poster")
      end

      it "redirects when the page is gone" do
        get edit_admin_dashboard_kit_page_path(id: 0)

        expect(response).to redirect_to(admin_dashboard_kit_pages_path)
      end
    end

    describe "editable templates" do
      let(:link) { "https://www.canva.com/design/DAGabc123/xyz/view" }

      before { sign_in admin }

      it "saves the rows the repeater posts" do
        post admin_dashboard_kit_pages_path, params: base_params(
          canva_templates: [
            { label: "Lanyard card", url: link, description: "Two per page" },
          ],
        )

        expect(KitPage.last.canva_templates).to eq(
          [{ "label" => "Lanyard card", "url" => link, "description" => "Two per page" }]
        )
      end

      # The form always renders a spare row, so a blank one is the normal case
      # and must not become a validation error.
      it "drops the blank spare rows the form always renders" do
        post admin_dashboard_kit_pages_path, params: base_params(
          canva_templates: [
            { label: "Lanyard card", url: link, description: "" },
            { label: "", url: "", description: "" },
            { label: "", url: "", description: "" },
          ],
        )

        expect(response).to have_http_status(:redirect)
        expect(KitPage.last.canva_templates.size).to eq(1)
      end

      it "trims whitespace off what was pasted" do
        post admin_dashboard_kit_pages_path, params: base_params(
          canva_templates: [{ label: "  Card  ", url: "  #{link}  ", description: "" }],
        )

        expect(KitPage.last.canva_templates.sole.values_at("label", "url")).to eq(["Card", link])
      end

      it "re-renders with an error and keeps the typed rows when a link is refused" do
        bad = "https://example.com/design/DAGabc/x/view"

        expect {
          post admin_dashboard_kit_pages_path, params: base_params(
            canva_templates: [{ label: "Lanyard card", url: bad, description: "" }],
          )
        }.not_to change(KitPage, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        # The refusal has to NAME both accepted shapes — listing only the
        # /design/ one is what made a valid short-link paste look like a bug.
        expect(response.body).to include("canva.com/design/")
        expect(response.body).to include("canva.link/")
        expect(response.body).to include(bad)
        expect(response.body).to include("Lanyard card")
      end

      # A row with a label and no link is a typo, not a spare row — the admin
      # must be told rather than have it silently swallowed.
      it "refuses a half-filled row rather than dropping it" do
        expect {
          post admin_dashboard_kit_pages_path, params: base_params(
            canva_templates: [{ label: "Lanyard card", url: "", description: "" }],
          )
        }.not_to change(KitPage, :count)

        expect(response.body).to include("needs a Canva link")
      end

      it "refuses more rows than the cap" do
        rows = Array.new(KitPage::MAX_TEMPLATES + 1) { { label: "Card", url: link, description: "" } }

        expect { post admin_dashboard_kit_pages_path, params: base_params(canva_templates: rows) }
          .not_to change(KitPage, :count)

        expect(response.body).to include("at most #{KitPage::MAX_TEMPLATES}")
      end

      it "clears every template when the rows are emptied" do
        page = create(:kit_page, canva_templates: [{ "label" => "Card", "url" => link }])

        patch admin_dashboard_kit_page_path(page), params: base_params(
          slug: page.slug,
          canva_templates: [{ label: "", url: "", description: "" }],
        )

        expect(page.reload.canva_templates).to eq([])
      end

      it "renders the templates card on the new-page form" do
        get new_admin_dashboard_kit_page_path

        expect(response.body).to include("Editable templates")
        expect(response.body).to include("canva_templates[][url]")
      end
    end
  end
end
