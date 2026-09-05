require "rails_helper"

RSpec.describe KitPage, type: :model do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner) }
  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
  end

  describe "validations" do
    it "requires a kebab-case slug" do
      expect(build(:kit_page, slug: "At School")).not_to be_valid
      expect(build(:kit_page, slug: "at_school")).not_to be_valid
      expect(build(:kit_page, slug: "at-school")).to be_valid
    end

    it "requires the slug to be unique" do
      create(:kit_page, slug: "at-school")
      expect(build(:kit_page, slug: "at-school")).not_to be_valid
    end

    it "requires a title" do
      expect(build(:kit_page, title: nil)).not_to be_valid
    end

    it "only accepts a real printable variant" do
      expect(build(:kit_page, printable_variant: "sideways")).not_to be_valid
      (BoardPrintable::DOWNLOAD_VARIANTS + [BoardPrintable::VARIANT_FULL]).each do |variant|
        expect(build(:kit_page, printable_variant: variant)).to be_valid
      end
    end

    it "rejects content whose items or closing are the wrong shape" do
      expect(build(:kit_page, content: { "items" => "nope" })).not_to be_valid
      expect(build(:kit_page, content: { "items" => ["nope"] })).not_to be_valid
      expect(build(:kit_page, content: { "closing" => [] })).not_to be_valid
      expect(build(:kit_page, content: { "items" => [{ "title" => "x" }], "closing" => { "body" => "y" } }))
        .to be_valid
    end
  end

  describe "#lead_source" do
    it "prefixes the slug so leads are discriminable in download_leads" do
      expect(build(:kit_page, slug: "at-school").lead_source).to eq("kit_at-school")
    end
  end

  describe ".for_lead_source" do
    it "finds the page behind a kit_ source, published or not" do
      page = create(:kit_page, slug: "at-school", published: false)
      expect(described_class.for_lead_source("kit_at-school")).to eq(page)
    end

    it "ignores the sources that predate kit pages" do
      expect(described_class.for_lead_source("classroom_kit")).to be_nil
      expect(described_class.for_lead_source("ctg")).to be_nil
      expect(described_class.for_lead_source("free_download")).to be_nil
      expect(described_class.for_lead_source(nil)).to be_nil
    end

    it "returns nil for a page that no longer exists" do
      expect(described_class.for_lead_source("kit_gone")).to be_nil
    end
  end

  describe "#resolved_mailchimp_tag" do
    it "derives a CamelCase tag from the slug, hyphens and all" do
      expect(build(:kit_page, slug: "at-school").resolved_mailchimp_tag).to eq("AtSchoolLead")
      expect(build(:kit_page, slug: "kit").resolved_mailchimp_tag).to eq("KitLead")
    end

    it "prefers an explicit tag" do
      expect(build(:kit_page, slug: "at-school", mailchimp_tag: "BackToSchool2026").resolved_mailchimp_tag)
        .to eq("BackToSchool2026")
    end
  end

  describe "#download_files / #downloadable?" do
    subject(:page) { create(:kit_page, board_printable: printable, printable_variant: "color") }

    it "is not downloadable without a printable" do
      expect(create(:kit_page, board_printable: nil)).not_to be_downloadable
    end

    it "is not downloadable while the printable is still generating" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF", variant: "color")
      printable.update!(status: "generating")

      expect(page.reload).not_to be_downloadable
    end

    it "is not downloadable when the printable carries no PDF" do
      expect(page).not_to be_downloadable
      expect(page.download_files).to eq([])
    end

    it "returns only the chosen variant when present" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF c", variant: "color")
      printable.attach_pdf!(filename: "a.low-ink.pdf", bytes: "%PDF l", variant: "low_ink")

      expect(page.download_files.map { |f| f[:variant] }).to eq(["color"])
      expect(page).to be_downloadable
    end

    it "falls back to every PDF when the chosen variant is absent" do
      printable.attach_pdf!(filename: "a.pdf", bytes: "%PDF f", variant: BoardPrintable::VARIANT_FULL)

      expect(page.download_files.map { |f| f[:variant] }).to eq(["full"])
    end

    # files_view is the PDF allowlist. A listing image must never be handed to
    # a visitor as the download.
    it "never returns a marketing image" do
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)

      expect(page.download_files).to eq([])
      expect(page).not_to be_downloadable
    end
  end

  describe "uploaded documents" do
    let(:page) { create(:kit_page, board_printable: printable) }

    def upload!(kit_page, filename: "handout.pdf", label: nil, bytes: "%PDF handout")
      kit_page.attach_document!(io: StringIO.new(bytes), filename: filename, label: label)
    end

    it "hands over the uploaded documents instead of the printable's PDFs" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF c", variant: "color")
      upload!(page)

      expect(page).to be_uploaded_download
      expect(page.download_files.map { |f| f[:filename] }).to eq(["handout.pdf"])
      expect(page).to be_downloadable
    end

    it "goes back to the printable once every document is removed" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF c", variant: "color")
      upload!(page)
      page.documents.each(&:purge)
      page.documents.reset

      expect(page.reload).not_to be_uploaded_download
      expect(page.download_files.map { |f| f[:variant] }).to eq(["color"])
    end

    it "is downloadable on an uploaded document alone, with no printable" do
      page = create(:kit_page, board_printable: nil)
      upload!(page)

      expect(page).to be_downloadable
    end

    # `variant` is what the frontend prints on the button.
    it "labels the button with the admin's label, falling back to the filename" do
      upload!(page, filename: "parent-handout.pdf")
      upload!(page, filename: "spanish.pdf", label: "En español")

      expect(page.download_files.map { |f| f[:variant] }).to eq(["parent-handout", "En español"])
    end

    it "carries both the preview URL and the presigned save URL" do
      upload!(page)

      expect(page.download_files.first.keys)
        .to match_array(%i[variant filename url byte_size download_url])
      expect(page.download_files.first[:url]).to be_present
    end

    it "keeps the printable's mockups out of an uploaded page's gallery" do
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)
      upload!(page)

      expect(page.gallery_images).to eq([])
    end

    it "shows the rendered pages of the uploaded document, first page first" do
      upload!(page)
      page.attach_preview_image!(bytes: "PNG two", page: 2)
      page.attach_preview_image!(bytes: "PNG one", page: 1)

      expect(page.gallery_images.map { |image| image[:variant] }).to eq(%w[page_1 page_2])
      expect(page.gallery_images.map(&:keys)).to all(match_array(%i[variant url page label]))
    end

    it "purges every preview" do
      upload!(page)
      page.attach_preview_image!(bytes: "PNG", page: 1)
      page.purge_preview_images!

      expect(page.reload.preview_images).to be_empty
      expect(page.gallery_images).to eq([])
    end

    # Same CloudFront lesson as BoardPrintable: it caches by path and ignores
    # query strings, so a stable key serves the previous document for hours.
    it "writes each upload to its own versioned key" do
      upload!(page, filename: "handout.pdf", bytes: "%PDF one")
      first = page.ordered_documents.first.key
      page.documents.each(&:purge)
      page.documents.reset
      upload!(page, filename: "handout.pdf", bytes: "%PDF two")

      expect(page.reload.ordered_documents.first.key).not_to eq(first)
    end

    it "still carries no file URL in the public payload" do
      upload!(page)
      page.attach_preview_image!(bytes: "PNG", page: 1)

      expect(page.public_view[:downloadable]).to eq(true)
      expect(page.public_view[:images].map { |i| i[:url] }.join).not_to include(".pdf")
      expect(page.public_view.to_s).not_to include("handout.pdf")
    end
  end

  describe "which rendered pages show where" do
    let(:page) { create(:kit_page) }

    def upload!(kit_page = page, filename: "handout.pdf", label: nil)
      kit_page.attach_document!(io: StringIO.new("%PDF #{filename}"), filename: filename, label: label)
    end

    # Two documents of three pages each, so ordering, defaults and per-document
    # attribution all have something to be wrong about.
    def render_two_documents!
      first = upload!(page, filename: "handout.pdf", label: "Parent handout")
      second = upload!(page, filename: "guide.pdf", label: "Teacher guide")
      [first, second].each do |document|
        (1..3).each { |n| page.attach_preview_image!(bytes: "PNG", page: n, document_id: document.id) }
      end
      [first, second]
    end

    it "orders every rendered page by document, then by page" do
      first, second = render_two_documents!

      expect(page.preview_rows.map { |row| [row[:document_id], row[:page]] })
        .to eq([[first.id.to_s, 1], [first.id.to_s, 2], [first.id.to_s, 3],
                [second.id.to_s, 1], [second.id.to_s, 2], [second.id.to_s, 3]])
    end

    # The whole point of an empty hash: this change may not move a live page.
    it "publishes only the first pages of the FIRST document when nothing is chosen" do
      first, = render_two_documents!

      expect(page).not_to be_previews_curated
      expect(page.public_preview_images.map { |i| i[:page] }).to eq([1, 2])
      expect(page.preview_rows.select { |r| r[:visibility] == KitPage::PREVIEW_PUBLIC }.map { |r| r[:document_id] })
        .to all(eq(first.id.to_s))
    end

    it "publishes exactly what a non-empty hash names, and hides anything it doesn't" do
      first, second = render_two_documents!
      page.update!(preview_settings: {
        KitPage.preview_setting_key(first.id, 1) => KitPage::PREVIEW_PUBLIC,
        KitPage.preview_setting_key(second.id, 2) => KitPage::PREVIEW_GATED,
      })

      expect(page.public_preview_images.map { |i| i[:page] }).to eq([1])
      expect(page.released_preview_images.map { |i| i[:page] }).to eq([1, 2])
      # Page 2 of the FIRST document was public under the default and is not named here.
      expect(page.preview_rows.find { |r| r[:key] == KitPage.preview_setting_key(first.id, 2) }[:visibility])
        .to eq(KitPage::PREVIEW_HIDDEN)
    end

    it "keeps every public page in the released list, in the same order" do
      first, = render_two_documents!
      page.update!(preview_settings: {
        KitPage.preview_setting_key(first.id, 1) => KitPage::PREVIEW_GATED,
        KitPage.preview_setting_key(first.id, 2) => KitPage::PREVIEW_PUBLIC,
      })

      expect(page.released_preview_images.map { |i| i[:page] }).to eq([1, 2])
      expect(page.public_preview_images).to all(be_in(page.released_preview_images))
    end

    it "names the document on a multi-document page and only the page on a single one" do
      first, = render_two_documents!

      expect(page.preview_rows.first[:document_label]).to eq("Parent handout")
      expect(page.public_preview_images.first[:label]).to eq("Parent handout — page 1")

      page.documents.reject { |d| d.blob_id == first.id }.each(&:purge)
      page.documents.reset
      page.send(:reset_file_memos)

      expect(page.public_preview_images.first[:label]).to eq("Page 1")
    end

    # Every preview rendered before multi-document support carries no document
    # id, and historically WAS the first document. Without this the live page
    # goes blank the moment this deploys.
    it "attributes a preview with no document id to the first document" do
      first = upload!(page, filename: "handout.pdf")
      page.attach_preview_image!(bytes: "PNG", page: 1)

      expect(page.preview_rows.map { |row| row[:document_id] }).to eq([first.id.to_s])
      expect(page.public_preview_images.map { |i| i[:page] }).to eq([1])
    end

    it "drops the rendered pages of a document that has been removed" do
      first, second = render_two_documents!
      page.documents.find { |d| d.blob_id == first.id }.purge
      page.documents.reset
      page.send(:reset_file_memos)

      expect(page.preview_rows.map { |row| row[:document_id] }.uniq).to eq([second.id.to_s])
    end

    describe "#update_preview_settings!" do
      it "writes what it is given" do
        first, = render_two_documents!
        page.update_preview_settings!(KitPage.preview_setting_key(first.id, 3) => KitPage::PREVIEW_GATED)

        expect(page.reload.preview_settings).to eq(KitPage.preview_setting_key(first.id, 3) => "gated")
      end

      # The form is the injection surface: a key naming another page's document
      # must never reach the column.
      it "ignores a key that names no page on this record" do
        first, = render_two_documents!
        page.update_preview_settings!(
          KitPage.preview_setting_key(first.id, 1) => KitPage::PREVIEW_PUBLIC,
          "999999:1" => KitPage::PREVIEW_PUBLIC,
          KitPage.preview_setting_key(first.id, 99) => KitPage::PREVIEW_PUBLIC,
        )

        expect(page.reload.preview_settings.keys).to eq([KitPage.preview_setting_key(first.id, 1)])
      end

      it "ignores a visibility that isn't one of the three" do
        first, = render_two_documents!
        page.update_preview_settings!(KitPage.preview_setting_key(first.id, 1) => "everywhere")

        expect(page.reload.preview_settings).to eq({})
      end

      # A document whose render hasn't landed yet has no rows, so a wholesale
      # replacement would silently drop choices already made about it.
      it "preserves settings for a document that is attached but not yet rendered" do
        first, = render_two_documents!
        pending_doc = upload!(page, filename: "third.pdf")
        page.update!(preview_settings: {
          KitPage.preview_setting_key(pending_doc.id, 1) => KitPage::PREVIEW_PUBLIC,
        })

        page.update_preview_settings!(KitPage.preview_setting_key(first.id, 1) => KitPage::PREVIEW_GATED)

        expect(page.reload.preview_settings).to eq(
          KitPage.preview_setting_key(pending_doc.id, 1) => "public",
          KitPage.preview_setting_key(first.id, 1) => "gated",
        )
      end

      it "prunes settings whose document has been removed" do
        first, second = render_two_documents!
        page.update!(preview_settings: {
          KitPage.preview_setting_key(first.id, 1) => KitPage::PREVIEW_PUBLIC,
          KitPage.preview_setting_key(second.id, 1) => KitPage::PREVIEW_PUBLIC,
        })
        page.documents.find { |d| d.blob_id == first.id }.purge
        page.documents.reset

        page.prune_preview_settings!

        expect(page.reload.preview_settings.keys).to eq([KitPage.preview_setting_key(second.id, 1)])
      end
    end

    describe ".preview_render_limit" do
      it "reads ENV at call time rather than freezing a constant" do
        expect(KitPage.preview_render_limit).to eq(KitPage::DEFAULT_PREVIEW_RENDER_LIMIT)

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("KIT_PREVIEW_RENDER_LIMIT", anything).and_return("4")

        expect(KitPage.preview_render_limit).to eq(4)
      end
    end
  end

  describe "preview tokens" do
    let(:draft) { create(:kit_page, slug: "draft-kit", published: false) }

    it "recognizes a token it minted for this page" do
      expect(described_class.valid_preview_token?(draft.slug, draft.preview_token)).to be(true)
    end

    # The payload is the slug precisely so this can't happen.
    it "refuses a token minted for another page" do
      other = create(:kit_page, slug: "other-draft", published: false)

      expect(described_class.valid_preview_token?(draft.slug, other.preview_token)).to be(false)
    end

    it "refuses garbage, blanks and nil without raising" do
      expect(described_class.valid_preview_token?(draft.slug, "nonsense")).to be(false)
      expect(described_class.valid_preview_token?(draft.slug, "")).to be(false)
      expect(described_class.valid_preview_token?(draft.slug, nil)).to be(false)
      expect(described_class.valid_preview_token?(nil, draft.preview_token)).to be(false)
    end

    it "refuses a token past its expiry" do
      token = draft.preview_token

      travel_to(described_class::PREVIEW_TOKEN_TTL.from_now + 1.minute) do
        expect(described_class.valid_preview_token?(draft.slug, token)).to be(false)
      end
    end

    describe ".for_public" do
      it "returns a published page with or without a token" do
        live = create(:kit_page, slug: "live-kit", published: true)

        expect(described_class.for_public("live-kit")).to eq(live)
        expect(described_class.for_public("live-kit", preview_token: "junk")).to eq(live)
      end

      it "returns a draft only for a valid token" do
        expect(described_class.for_public(draft.slug)).to be_nil
        expect(described_class.for_public(draft.slug, preview_token: "junk")).to be_nil
        expect(described_class.for_public(draft.slug, preview_token: draft.preview_token)).to eq(draft)
      end

      it "returns nil for a slug that doesn't exist" do
        expect(described_class.for_public("no-such-page")).to be_nil
      end
    end
  end

  describe "canva templates" do
    let(:link) { "https://www.canva.com/design/DAGabc123/xyz/view" }

    def page_with(templates)
      build(:kit_page, canva_templates: templates)
    end

    describe "validation" do
      it "accepts a well-formed row" do
        expect(page_with([{ "label" => "Lanyard card", "url" => link }])).to be_valid
      end

      it "accepts the bare canva.com host" do
        expect(page_with([{ "label" => "Card", "url" => "https://canva.com/design/DAGabc/x/view" }])).to be_valid
      end

      # Canva's own Share menu hands out short links as readily as full design
      # URLs; refusing them made the feature look broken on a valid paste.
      it "accepts a canva.link short link" do
        expect(page_with([{ "label" => "Card", "url" => "https://canva.link/1o8k9nz2xecjq2a" }])).to be_valid
      end

      it "refuses the bare shortener domain, which names no design" do
        page = page_with([{ "label" => "Card", "url" => "https://canva.link/" }])
        expect(page).not_to be_valid
      end

      it "refuses a value that isn't a list" do
        page = page_with("nope")
        expect(page).not_to be_valid
        expect(page.errors[:canva_templates].join).to include("must be a list")
      end

      it "refuses a row that isn't an object" do
        page = page_with(["https://www.canva.com/design/x/y/view"])
        expect(page).not_to be_valid
        expect(page.errors[:canva_templates].join).to include("must be an object")
      end

      it "refuses a row with no label" do
        page = page_with([{ "url" => link }])
        expect(page).not_to be_valid
        expect(page.errors[:canva_templates].join).to include("needs a label")
      end

      it "refuses a row with no link" do
        page = page_with([{ "label" => "Card" }])
        expect(page).not_to be_valid
        expect(page.errors[:canva_templates].join).to include("needs a Canva link")
      end

      # The allowlist, one rejection per rule it enforces. Note a LOOKALIKE
      # host is the case the allowlist exists for.
      it "refuses http, a foreign host, a lookalike, and a canva.com URL outside /design/" do
        [
          "http://www.canva.com/design/DAGabc/x/view",
          "http://canva.link/1o8k9nz2xecjq2a",
          "https://canva.example.com/design/DAGabc/x/view",
          "https://canva.link.example.com/1o8k9nz2xecjq2a",
          "https://www.canva.com/templates/xyz",
          "not a url at all",
        ].each do |bad|
          page = page_with([{ "label" => "Card", "url" => bad }])
          expect(page).not_to be_valid, "expected #{bad.inspect} to be refused"
          expect(page.errors[:canva_templates].join).to include("canva.link")
        end
      end

      it "refuses more rows than the cap" do
        rows = Array.new(KitPage::MAX_TEMPLATES + 1) { { "label" => "Card", "url" => link } }
        page = page_with(rows)
        expect(page).not_to be_valid
        expect(page.errors[:canva_templates].join).to include("at most #{KitPage::MAX_TEMPLATES}")
      end

      it "defaults to an empty list" do
        expect(create(:kit_page).canva_templates).to eq([])
      end
    end

    describe "#has_templates? and #offers_anything?" do
      it "is false with no templates and no printable" do
        page = create(:kit_page)
        expect(page.has_templates?).to eq(false)
        expect(page.offers_anything?).to eq(false)
      end

      # The whole point: a page may offer ONLY templates, and the email gate
      # still has to open for it.
      it "offers something on templates alone, while downloadable? stays false" do
        page = create(:kit_page, canva_templates: [{ "label" => "Card", "url" => link }])

        expect(page.has_templates?).to eq(true)
        expect(page.downloadable?).to eq(false)
        expect(page.offers_anything?).to eq(true)
      end
    end

    describe "#template_teasers and #template_links" do
      let(:page) do
        create(:kit_page, canva_templates: [
                 { "label" => "Lanyard card", "url" => link, "description" => "Two per page" },
               ])
      end

      it "publishes the label and description but never the link" do
        teaser = page.template_teasers.sole

        expect(teaser).to eq(label: "Lanyard card", description: "Two per page")
        expect(teaser.keys).not_to include(:url)
      end

      it "carries the link on the gated view" do
        expect(page.template_links.sole).to eq(
          label: "Lanyard card", description: "Two per page", url: link
        )
      end

      it "reports a blank description as nil rather than an empty string" do
        page = create(:kit_page, canva_templates: [{ "label" => "Card", "url" => link, "description" => "" }])

        expect(page.template_teasers.sole[:description]).to be_nil
      end
    end
  end

  describe "#public_view" do
    it "carries no file URL" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF", variant: "color")
      page = create(:kit_page, board_printable: printable)

      expect(page.public_view.keys).to match_array(
        %i[slug title eyebrow subhead content cta_label cta_path downloadable images templates]
      )
      expect(page.public_view[:downloadable]).to eq(true)
      expect(page.public_view.values_at(:slug, :title)).to all(be_present)
    end

    it "carries template labels and never a template link" do
      link = "https://www.canva.com/design/DAGabc123/xyz/view"
      page = create(:kit_page, canva_templates: [
                      { "label" => "Lanyard card", "url" => link, "description" => "Two per page" },
                    ])

      expect(page.public_view[:templates]).to eq(
        [{ label: "Lanyard card", description: "Two per page" }]
      )
      expect(page.public_view.to_json).not_to include("canva.com")
    end

    it "still carries no PDF URL once the mockups are in the payload" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF", variant: "color")
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)
      page = create(:kit_page, board_printable: printable)

      urls = page.public_view[:images].map { |image| image[:url] }
      expect(urls).to be_present
      expect(urls.join).not_to include(".pdf")
    end
  end

  describe "#gallery_images" do
    it "returns the curated variants, in landing-page order" do
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_ON_A_DEVICE)
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_ON_PAPER)
      page = create(:kit_page, board_printable: printable)

      expect(page.gallery_images.map { |image| image[:variant] })
        .to eq([BoardPrintable::IMAGE_HERO, BoardPrintable::IMAGE_ON_PAPER, BoardPrintable::IMAGE_ON_A_DEVICE])
    end

    it "leaves out gallery images that are Etsy shop framing" do
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_ABOUT)
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_PAGE_INDEX)
      page = create(:kit_page, board_printable: printable)

      expect(page.gallery_images.map { |image| image[:variant] }).to eq([BoardPrintable::IMAGE_HERO])
    end

    it "carries only the variant and the URL" do
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)
      page = create(:kit_page, board_printable: printable)

      expect(page.gallery_images.first.keys).to match_array(%i[variant url])
    end

    it "is empty with no printable" do
      expect(create(:kit_page, board_printable: nil).gallery_images).to eq([])
    end

    it "is empty while the printable is still generating" do
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)
      printable.update!(status: "pending")

      expect(create(:kit_page, board_printable: printable.reload).gallery_images).to eq([])
    end

    it "is empty when the printable carries only PDFs" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF", variant: "color")

      expect(create(:kit_page, board_printable: printable).gallery_images).to eq([])
    end

    it "drops an image whose URL can't be resolved" do
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_HERO)
      printable.attach_image!(bytes: "PNG", variant: BoardPrintable::IMAGE_ON_PAPER)
      page = create(:kit_page, board_printable: printable)
      allow(page.board_printable).to receive(:listing_images_view).and_return([
        { variant: BoardPrintable::IMAGE_HERO, url: nil },
        { variant: BoardPrintable::IMAGE_ON_PAPER, url: "https://cdn.example/on-paper.png" },
      ])

      expect(page.gallery_images).to eq([{ variant: BoardPrintable::IMAGE_ON_PAPER, url: "https://cdn.example/on-paper.png" }])
    end
  end

  describe "#gives_away_protected_printable?" do
    it "is true only for a printable that was published to Etsy and not waived" do
      page = create(:kit_page, board_printable: printable)
      expect(page).not_to be_gives_away_protected_printable

      printable.update!(etsy_published_at: Time.current, etsy_listing_id: 123)
      expect(page.reload).to be_gives_away_protected_printable
    end

    it "is false with no printable at all" do
      expect(create(:kit_page, board_printable: nil)).not_to be_gives_away_protected_printable
    end
  end
end
