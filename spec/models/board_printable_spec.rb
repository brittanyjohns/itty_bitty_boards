require "rails_helper"

RSpec.describe BoardPrintable do
  it "is destroyed along with its board" do
    board = FactoryBot.create(:board)
    printable = described_class.create!(board: board, board_ids: [board.id])

    expect { board.destroy! }.not_to raise_error
    expect(described_class.exists?(printable.id)).to be false
  end

  describe "PDFs vs listing images" do
    let(:board) { FactoryBot.create(:board, name: "Core Words") }
    let(:printable) do
      described_class.create!(board: board, status: "complete", board_ids: [board.id])
    end

    before do
      printable.attach_pdf!(filename: "core.pdf", bytes: "pdf", variant: described_class::VARIANT_FULL)
      printable.attach_image!(bytes: "png", variant: described_class::IMAGE_HERO)
      printable.reload
    end

    it "keeps files_view to PDFs only, so the download buttons never offer marketing art" do
      expect(printable.files_view.map { |f| f[:filename] }).to eq(["core.pdf"])
    end

    it "exposes the images separately, in listing rank order" do
      printable.attach_image!(bytes: "png", variant: described_class::IMAGE_ABOUT)
      printable.attach_image!(bytes: "png", variant: described_class::IMAGE_WHATS_INCLUDED)

      expect(printable.reload.listing_images_view.map { |i| i[:variant] })
        .to eq([described_class::IMAGE_HERO, described_class::IMAGE_WHATS_INCLUDED,
                described_class::IMAGE_ABOUT])
    end

    # A blob from any retired gallery design would otherwise sort to the end of
    # listing_images_view and get uploaded to Etsy as a real listing photo. All
    # three are covered, not just the oldest: `how_it_works` and
    # `whats_included_low_ink` were dropped when the gallery grew its photoreal
    # mockups and hit Etsy's ten-photo cap exactly.
    describe "images left over from a retired gallery design" do
      let(:retired) do
        [described_class::IMAGE_COVER, described_class::IMAGE_HOW_IT_WORKS,
          described_class::IMAGE_WHATS_INCLUDED_LOW_INK]
      end

      before { retired.each { |variant| printable.attach_image!(bytes: "old", variant: variant) } }

      it "is not one of the variants the gallery still renders" do
        expect(described_class::LISTING_IMAGE_ORDER & retired).to be_empty
      end

      it "are hidden from the gallery view" do
        expect(printable.reload.listing_images_view.map { |i| i[:variant] })
          .not_to include(*retired)
      end

      it "make the printable read as not current, so publishing re-renders" do
        expect(printable.reload.listing_images?).to be true
        expect(printable.listing_images_current?).to be false
      end

      it "are purged on request, leaving the current slides alone" do
        described_class::LISTING_IMAGE_ORDER.each do |variant|
          printable.attach_image!(bytes: "png", variant: variant)
        end

        printable.reload.purge_legacy_listing_images!

        expect(printable.reload.image_files.map { |f| f.metadata["variant"] })
          .to match_array(described_class::LISTING_IMAGE_ORDER)
        expect(printable.listing_images_current?).to be true
      end
    end

    it "treats a blob written before the kind metadata existed as a PDF" do
      legacy = printable.pdf_files.first
      legacy.blob.update!(metadata: legacy.metadata.except("kind"))

      expect(printable.reload.files_view.length).to eq(1)
      expect(printable.image_files.length).to eq(1)
    end

    it "replaces an image variant instead of accumulating renders" do
      printable.attach_image!(bytes: "png-2", variant: described_class::IMAGE_HERO)

      expect(printable.reload.image_files.length).to eq(1)
    end

    # #pdf_files is an ALLOWLIST, and these are why. It used to select by
    # exclusion (`kind != KIND_IMAGE`), which made a video a PDF everywhere the
    # partition is read.
    describe "a listing video blob" do
      before do
        printable.files.attach(
          ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new("mp4"),
            filename: "flip-through.mp4",
            content_type: "video/mp4",
            key: printable.versioned_storage_key_for("flip-through.mp4"),
            metadata: { "kind" => described_class::KIND_VIDEO, "variant" => "flip_through" },
          ),
        )
        printable.reload
      end

      it "is neither a download nor a gallery image" do
        expect(printable.pdf_files.map { |f| f.filename.to_s }).to eq(["core.pdf"])
        expect(printable.image_files.length).to eq(1)
        expect(printable.current_image_files.map { |f| f.metadata["variant"] })
          .to eq([described_class::IMAGE_HERO])
      end

      it "is never offered to a buyer as a download" do
        expect(printable.files_view.map { |f| f[:filename] }).to eq(["core.pdf"])
        expect(printable.api_view[:files].map { |f| f[:filename] }).to eq(["core.pdf"])
      end

      # The silent one: Boards::Printables::Generate calls this with only the
      # keys of the PDFs it just wrote, so a video counted as a PDF would be
      # destroyed by every "Regenerate" with no error anywhere.
      it "survives a PDF regeneration" do
        # Boards::Printables::Generate passes the keys of the blobs IT just
        # attached, so the keep list is PDFs and nothing else — which is what
        # made the old denylist delete the video here.
        fresh = printable.attach_pdf!(filename: "core.pdf", bytes: "pdf-2", variant: described_class::VARIANT_FULL)

        printable.reload.purge_stale_pdfs!([fresh.key])

        expect(printable.reload.files.map { |f| f.metadata["kind"] }).to include(described_class::KIND_VIDEO)
        expect(printable.pdf_files.map(&:key)).to eq([fresh.key])
      end
    end
  end

  describe "#listing_copy_or_default" do
    let(:board) { FactoryBot.create(:board, name: "Core Words") }
    let(:printable) { described_class.create!(board: board, board_ids: [board.id]) }

    it "generates a preview when nothing has been saved" do
      expect(printable.listing_copy).to eq({})
      expect(printable.listing_copy_or_default["title"]).to include("Core Words")
    end

    it "returns the saved copy untouched once it exists" do
      printable.update!(listing_copy: { "title" => "Edited by hand" })

      expect(printable.listing_copy_or_default).to eq({ "title" => "Edited by hand" })
    end
  end

  describe "#board_page_count" do
    let(:board) { FactoryBot.create(:board) }

    # A one-board printable merges to seven pages — cover, how-to-use, the
    # three board pages, license, credits — and only the three are the product.
    it "counts each board once per download variant, ignoring the wrappers" do
      printable = described_class.create!(board: board, board_ids: [board.id], page_count: 7)

      expect(printable.board_page_count).to eq(3)
    end

    it "scales with the boards in a bundle" do
      other = FactoryBot.create(:board)
      printable = described_class.create!(board: board, board_ids: [board.id, other.id], page_count: 18)

      expect(printable.board_page_count).to eq(6)
    end

    # Nothing has been walked yet, so the copy has to fall back to a headline
    # with no number rather than claiming zero pages.
    it "is zero before the printable has been generated" do
      expect(described_class.create!(board: board).board_page_count).to eq(0)
    end
  end

  describe "#etsy_published?" do
    let(:board) { FactoryBot.create(:board) }
    let(:printable) { described_class.create!(board: board, board_ids: [board.id]) }

    it "is false until a listing id is recorded" do
      expect(printable.etsy_published?).to be false
      printable.update!(etsy_listing_id: 123)
      expect(printable.etsy_published?).to be true
    end
  end

  describe "detaching a listing" do
    let(:board) { FactoryBot.create(:board, name: "Core Words") }
    let(:printable) do
      described_class.create!(board: board, status: "complete", board_ids: [board.id])
    end
    let!(:listing) do
      printable.etsy_listings.create!(
        etsy_listing_id: 987, etsy_listing_url: "https://etsy.test/987",
        state: "published", published_at: 3.days.ago,
      )
    end

    # The orphaning fix. Detaching used to NULL the id and leave the draft
    # unfindable; the row keeps it, because this app implements no delete call
    # and someone has to be told which listing to remove on Etsy.
    it "supersedes the row and keeps the listing id" do
      listing.supersede!

      expect(listing.reload).to have_attributes(state: "superseded", etsy_listing_id: 987)
      expect(printable.reload.etsy_published?).to be false
      expect(printable.etsy_ever_published?).to be true
    end

    # The whole reason protection is not keyed on being attached. Detaching must
    # not unfreeze boards whose printed pages are already in someone's hands.
    it "keeps the boards it protects frozen" do
      expect { listing.supersede! }.not_to change { printable.reload.protects_board? }.from(true)
    end

    it "stays protected in the query the board guard actually uses" do
      listing.supersede!

      expect(Boards::MarketplaceProtection.new(board).protected?).to be true
      expect(Boards::MarketplaceProtection.protected_board_ids([board.id])).to include(board.id)
    end

    it "leaves an explicit waiver alone" do
      printable.waive_protection!(user: FactoryBot.create(:admin_user), reason: "sold out")

      listing.supersede!

      expect(printable.reload.protection_waived?).to be true
      expect(printable.protects_board?).to be false
    end

    # Protection must never NARROW. A row carrying a listing id but no timestamp
    # protected its boards before listing rows existed, and still has to.
    it "protects a legacy row that has an id but no timestamp" do
      legacy = described_class.create!(board: board, status: "complete", board_ids: [board.id])
      legacy.update_columns(etsy_listing_id: 555, etsy_published_at: nil)

      expect(legacy.reload.protects_board?).to be true
      expect(Boards::MarketplaceProtection.protected_board_ids([board.id])).to include(board.id)
    end
  end

  describe "protection" do
    # A printable that was never published isn't protecting anything, and has no
    # listing to detach from.
    it "does not protect a printable that was never published" do
      fresh = described_class.create!(board: FactoryBot.create(:board), status: "complete")

      expect(fresh.etsy_ever_published?).to be false
      expect(fresh.protects_board?).to be false
    end
  end
end
