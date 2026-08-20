require "rails_helper"

RSpec.describe BoardPrintableListing do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user, name: "Daily Routines") }
  let(:printable) do
    BoardPrintable.create!(
      board: board, status: "complete", board_ids: [board.id], topic: "morning routine",
      listing_copy: { "title" => "Morning Routine Board", "price_cents" => 599, "tags" => %w[aac core] },
    )
  end

  def listing(**attrs) = printable.etsy_listings.create!(**attrs)

  it "is pending, standalone and attached to nothing when first allocated" do
    row = listing

    expect(row.state).to eq("pending")
    expect(row.purpose).to eq("standalone")
    expect(row.reached_etsy?).to be false
    expect(row.attached?).to be false
  end

  it "rejects a state or purpose outside the known set" do
    expect(described_class.new(board_printable: printable, state: "live")).not_to be_valid
    expect(described_class.new(board_printable: printable, purpose: "wholesale")).not_to be_valid
  end

  describe "#reached_etsy?" do
    it "is true once an id is set" do
      expect(listing(etsy_listing_id: 111, state: "published").reached_etsy?).to be true
    end

    # The union half that catches a row whose id was cleared by hand: a draft
    # was still made, and protection has to keep reading it as one.
    it "is true from published_at alone" do
      expect(listing(published_at: 1.day.ago, state: "superseded").reached_etsy?).to be true
    end
  end

  describe "#attached?" do
    it "is false once the row is superseded, even though the id survives" do
      row = listing(etsy_listing_id: 222, state: "published")
      row.supersede!

      expect(row.attached?).to be false
      expect(row.reached_etsy?).to be true
    end
  end

  # The orphan fix, expressed as a predicate: the id is persisted the instant
  # Etsy returns it, so a draft whose uploads then failed is still findable.
  describe "#assets_incomplete?" do
    it "is true when a draft exists but the uploads never finished" do
      expect(listing(etsy_listing_id: 333, state: "published", published_at: Time.current)
               .assets_incomplete?).to be true
    end

    it "is false once the uploads land" do
      expect(listing(etsy_listing_id: 444, state: "published",
                     published_at: Time.current, assets_uploaded_at: Time.current)
               .assets_incomplete?).to be false
    end
  end

  describe "#supersede!" do
    it "keeps the listing id, because the draft is still on Etsy for someone to delete" do
      row = listing(etsy_listing_id: 555, state: "published", published_at: 1.day.ago)

      row.supersede!

      expect(row.reload.etsy_listing_id).to eq(555)
      expect(row.state).to eq("superseded")
      expect(row.superseded_at).to be_present
    end

    # That video went to THAT listing. A replacement is a different row whose
    # stamp is nil by construction, so nothing has to remember to clear this.
    it "keeps the video stamp" do
      row = listing(etsy_listing_id: 666, state: "published", video_pushed_at: 1.hour.ago)

      row.supersede!

      expect(row.reload.video_pushed_at).to be_present
    end
  end

  describe "#resolved_copy" do
    it "falls back to the printable's copy when nothing is overridden" do
      expect(listing.resolved_copy["title"]).to eq("Morning Routine Board")
      expect(listing.resolved_copy["price_cents"]).to eq(599)
    end

    it "lets an override win" do
      row = listing(listing_copy: { "title" => "Morning Routine Bundle" }, purpose: "bundle")

      expect(row.resolved_copy["title"]).to eq("Morning Routine Bundle")
      expect(row.resolved_copy["tags"]).to eq(%w[aac core])
    end

    it "overrides the price independently of the title" do
      row = listing(listing_copy: { "price_cents" => 1299 }, purpose: "bundle")

      expect(row.resolved_copy["price_cents"]).to eq(1299)
      expect(row.resolved_copy["title"]).to eq("Morning Routine Board")
    end

    # A cleared form field means "use the printable's", not "send nothing" —
    # otherwise clearing the bundle's title publishes an empty one.
    it "treats a blank override as absent" do
      row = listing(listing_copy: { "title" => "" })

      expect(row.resolved_copy["title"]).to eq("Morning Routine Board")
    end
  end

  describe "#resolved_topic" do
    it "uses the printable's topic by default and the override when set" do
      expect(listing.resolved_topic).to eq("morning routine")
      expect(listing(topic_override: "school morning").resolved_topic).to eq("school morning")
    end
  end

  # Every partition is an ALLOWLIST over the printable's shared assets, never an
  # exclusion — the same rule that keeps the listing video out of a buyer's
  # download.
  describe "per-listing assets" do
    before do
      printable.attach_pdf!(filename: "core.color.pdf", bytes: "a", variant: BoardPrintable::VARIANT_COLOR)
      printable.attach_pdf!(filename: "core.low-ink.pdf", bytes: "b", variant: BoardPrintable::VARIANT_LOW_INK)
      BoardPrintable::LISTING_IMAGE_ORDER.each { |v| printable.attach_image!(bytes: "png", variant: v) }
      printable.reload
    end

    describe "#pdf_files" do
      it "ships every PDF when nothing is selected" do
        expect(listing.pdf_files.size).to eq(2)
      end

      it "ships only the selected variants" do
        row = listing(pdf_variants: [BoardPrintable::VARIANT_COLOR])

        expect(row.pdf_files.map { |f| f.metadata["variant"] }).to eq([BoardPrintable::VARIANT_COLOR])
      end

      # The intersection is what stops a per-listing subset becoming a second
      # way to hand a buyer something that isn't the product.
      it "can never reach a gallery image or the video" do
        printable.attach_video!(bytes: "mp4", duration: 9.0)
        row = listing(pdf_variants: BoardPrintableListing::PDF_VARIANTS)

        expect(row.pdf_files.map { |f| f.metadata["kind"] }.uniq).to eq([BoardPrintable::KIND_PDF])
      end

      it "refuses a variant it doesn't know" do
        row = described_class.new(board_printable: printable, pdf_variants: ["glossy"])

        expect(row).not_to be_valid
        expect(row.errors[:pdf_variants].join).to include("glossy")
      end
    end

    describe "#image_files" do
      it "inherits the shared gallery, in listing rank order" do
        expect(listing.image_files.map { |f| f.metadata["variant"] })
          .to eq(BoardPrintable::LISTING_IMAGE_ORDER)
      end

      it "narrows to the selected slides, keeping rank order" do
        row = listing(image_variants: [BoardPrintable::IMAGE_HERO, BoardPrintable::IMAGE_ON_PAPER])

        expect(row.image_files.map { |f| f.metadata["variant"] })
          .to eq([BoardPrintable::IMAGE_ON_PAPER, BoardPrintable::IMAGE_HERO])
      end

      it "prefers its own rendered slides over the shared ones" do
        row = listing(topic_override: "school morning")
        printable.attach_image!(bytes: "own", variant: BoardPrintable::IMAGE_HERO, listing: row)

        expect(row.reload.image_files.map { |f| f.metadata["variant"] }).to eq([BoardPrintable::IMAGE_HERO])
        expect(printable.reload.image_files.size).to eq(BoardPrintable::LISTING_IMAGE_ORDER.size)
      end

      # Rendering a listing's own hero used to delete the shared one, because
      # the purge matched on variant alone.
      it "does not clobber the shared gallery when its own is rendered" do
        row = listing
        printable.attach_image!(bytes: "own", variant: BoardPrintable::IMAGE_HERO, listing: row)

        shared = printable.reload.image_files.map { |f| f.metadata["variant"] }
        expect(shared).to match_array(BoardPrintable::LISTING_IMAGE_ORDER)
      end
    end

    describe "#video_file" do
      it "inherits the shared clip and prefers its own" do
        printable.attach_video!(bytes: "shared", duration: 9.0)
        row = listing
        expect(row.video_file.download).to eq("shared")

        printable.attach_video!(bytes: "own", duration: 9.0, listing: row)
        expect(row.reload.video_file.download).to eq("own")
        expect(printable.reload.video_file.download).to eq("shared")
      end
    end

    describe "#listing_images_current?" do
      it "is satisfied by the slides it actually selected" do
        expect(listing(image_variants: [BoardPrintable::IMAGE_HERO]).listing_images_current?).to be true
      end
    end
  end
end
