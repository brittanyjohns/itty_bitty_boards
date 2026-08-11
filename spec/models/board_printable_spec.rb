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

    # A blob from the retired two-image gallery would otherwise sort to the end
    # of listing_images_view and get uploaded to Etsy as a real listing photo.
    describe "images left over from the retired gallery design" do
      before { printable.attach_image!(bytes: "old", variant: described_class::IMAGE_COVER) }

      it "are hidden from the gallery view" do
        expect(printable.reload.listing_images_view.map { |i| i[:variant] })
          .not_to include(described_class::IMAGE_COVER)
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

  describe "#etsy_published?" do
    let(:board) { FactoryBot.create(:board) }
    let(:printable) { described_class.create!(board: board, board_ids: [board.id]) }

    it "is false until a listing id is recorded" do
      expect(printable.etsy_published?).to be false
      printable.update!(etsy_listing_id: 123)
      expect(printable.etsy_published?).to be true
    end
  end
end
