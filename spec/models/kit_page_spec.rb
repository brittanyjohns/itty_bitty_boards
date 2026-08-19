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

  describe "#public_view" do
    it "carries no file URL" do
      printable.attach_pdf!(filename: "a.color.pdf", bytes: "%PDF", variant: "color")
      page = create(:kit_page, board_printable: printable)

      expect(page.public_view.keys).to match_array(
        %i[slug title eyebrow subhead content cta_label cta_path downloadable images]
      )
      expect(page.public_view[:downloadable]).to eq(true)
      expect(page.public_view.values_at(:slug, :title)).to all(be_present)
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
