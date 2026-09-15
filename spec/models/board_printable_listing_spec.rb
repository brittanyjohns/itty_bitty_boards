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

    # `gallery_items` is an ordered allowlist of refs. Empty means "never
    # curated", which must be exactly the behaviour above.
    describe "a curated gallery" do
      def attach_styled!(variant = BoardPrintable::IMAGE_STYLED_HERO, digest: printable.styled_facts_digest,
                         spec_version: BoardPrintable::STYLED_SPEC_VERSION)
        printable.attach_image!(
          bytes: "styled", variant: variant,
          metadata: { spec_version: spec_version, facts_digest: digest },
        )
        printable.reload
      end

      def variants_of(row) = row.image_files.map { |f| f.metadata["variant"] }

      it "is not curated while gallery_items is empty, and keeps the legacy gallery" do
        row = listing

        expect(row.gallery_items).to eq([])
        expect(row.curated_gallery?).to be false
        expect(variants_of(row)).to eq(BoardPrintable::LISTING_IMAGE_ORDER)
      end

      it "resolves refs in the stored order, styled and legacy mixed" do
        attach_styled!
        row = listing(gallery_items: %w[styled:styled_hero legacy:about legacy:on_paper])

        expect(variants_of(row)).to eq([BoardPrintable::IMAGE_STYLED_HERO, "about", "on_paper"])
        expect(row.first_image_variant).to eq(BoardPrintable::IMAGE_STYLED_HERO)
        expect(row.listing_images_current?).to be true
      end

      # A curated gallery replaces the checkbox allowlist rather than being
      # narrowed by it.
      it "ignores image_variants once curated" do
        row = listing(gallery_items: %w[legacy:about], image_variants: [BoardPrintable::IMAGE_HERO])

        expect(variants_of(row)).to eq(["about"])
      end

      it "prefers the listing's own blob over the shared one" do
        row = listing(gallery_items: %w[legacy:on_paper legacy:about])
        printable.attach_image!(bytes: "own", variant: "on_paper", listing: row)

        expect(row.reload.image_files.map(&:download)).to eq(%w[own png])
      end

      it "is not current when a ref has no blob" do
        row = listing(gallery_items: %w[legacy:about styled:styled_hero])

        expect(variants_of(row)).to eq(["about"])
        expect(row.listing_images_current?).to be false
        expect(row.stale_gallery_refs.map(&:to_s)).to eq(["styled:styled_hero"])
      end

      it "is not current when a styled slide's facts or design moved" do
        attach_styled!(digest: "an-older-digest")
        expect(listing(gallery_items: %w[styled:styled_hero]).listing_images_current?).to be false

        attach_styled!(spec_version: BoardPrintable::STYLED_SPEC_VERSION - 1)
        expect(listing(gallery_items: %w[styled:styled_hero]).listing_images_current?).to be false
      end

      # Same rule as the uncurated path: an override is doing nothing until the
      # listing has slides of its own.
      it "is not current when a topic override is served the shared legacy slide" do
        row = listing(gallery_items: %w[legacy:about], topic_override: "school morning")
        expect(row.listing_images_current?).to be false

        printable.attach_image!(bytes: "own", variant: "about", listing: row)
        expect(row.reload.listing_images_current?).to be true
      end

      # A variant retired after it was saved must read stale, not quietly
      # shrink the gallery.
      it "is not current when a stored ref no longer parses" do
        row = listing(gallery_items: %w[legacy:about])
        row.update_column(:gallery_items, %w[legacy:about legacy:cover])

        expect(row.reload.listing_images_current?).to be false
      end

      describe "validation" do
        def build(items) = described_class.new(board_printable: printable, gallery_items: items)

        it "accepts up to ten known, unique refs" do
          expect(build(Printables::GalleryItemRef::SUGGESTED)).to be_valid
        end

        it "refuses an eleventh image" do
          eleven = Printables::GalleryItemRef.catalogue.map(&:to_s).first(11)
          row = build(eleven)

          expect(row).not_to be_valid
          expect(row.errors[:gallery_items].join).to match(/at most 10/)
        end

        it "refuses a duplicate" do
          row = build(%w[legacy:about legacy:about])

          expect(row).not_to be_valid
          expect(row.errors[:gallery_items].join).to include("more than once")
        end

        it "refuses an unknown prefix, an unknown variant, and a composition ref" do
          expect(build(%w[photo:on_paper]).tap(&:valid?).errors[:gallery_items].join).to match(/unknown kind/)
          expect(build(%w[legacy:glossy]).tap(&:valid?).errors[:gallery_items].join).to include("legacy:glossy")
          expect(build(%w[composition:3]).tap(&:valid?).errors[:gallery_items].join).to match(/can't be used yet/)
        end

        it "refuses a non-list" do
          expect(build("legacy:about")).not_to be_valid
        end
      end
    end
  end
end
