require "rails_helper"

RSpec.describe Boards::MarketplaceProtection do
  let(:user) { FactoryBot.create(:user) }
  let(:root) { FactoryBot.create(:board, user: user, name: "Daily Routines") }
  let(:page) { FactoryBot.create(:board, user: user, name: "Snack Time") }
  let(:unrelated) { FactoryBot.create(:board, user: user, name: "Something Else") }

  def printable(listing_id: 1234567890, boards: [root, page], **attrs)
    BoardPrintable.create!(
      board: root,
      status: "complete",
      board_ids: boards.map(&:id),
      etsy_listing_id: listing_id,
      etsy_listing_url: "https://www.etsy.com/listing/#{listing_id}",
      **attrs,
    )
  end

  it "protects the board the printable was generated from" do
    printable

    expect(described_class.new(root).protected?).to be true
    expect(described_class.new(root).role).to eq(:root)
  end

  # The whole point of covering board_ids: every interior page of a printed set
  # carries its own QR pointing at its own /pb/<slug>, so deleting page 4 breaks
  # the product exactly as badly as deleting the root.
  it "protects an interior page of the printed tree" do
    printable

    expect(described_class.new(page).protected?).to be true
    expect(described_class.new(page).role).to eq(:page)
  end

  it "leaves boards the printable never covered alone" do
    printable

    expect(described_class.new(unrelated).protected?).to be false
  end

  # Generating a printable to look at it is the normal way to use the admin.
  # Locking a board every time would make the feature something to avoid.
  it "does not protect until the printable reaches Etsy" do
    BoardPrintable.create!(board: root, status: "complete", board_ids: [root.id, page.id])

    expect(described_class.new(root).protected?).to be false
    expect(described_class.new(page).protected?).to be false
  end

  it "stops protecting once protection is waived" do
    record = printable
    expect(described_class.new(root).protected?).to be true

    record.waive_protection!(user: user, reason: "listing ended")

    expect(described_class.new(root).protected?).to be false
    expect(described_class.new(page).protected?).to be false
  end

  # A printable that failed before Generate wrote board_ids still names a real
  # board through its belongs_to, and that board is still what was sold.
  it "falls back to board_id when board_ids was never written" do
    printable(boards: [])

    expect(described_class.new(root).protected?).to be true
  end

  # board_ids holds INTEGERS (Boards::Printables::Generate writes
  # `collected[:boards].map(&:id)`). The `@>` containment lookup compares JSON
  # values, so a string would silently never match and every interior page
  # would quietly lose its protection.
  it "matches on integer board_ids, not strings" do
    record = printable
    expect(record.reload.board_ids).to all(be_a(Integer))

    record.update_column(:board_ids, [page.id.to_s])

    expect(described_class.new(page).protected?).to be false
  end

  describe ".protected_board_ids" do
    it "returns only the protected ids from the batch, in one query" do
      printable

      result = described_class.protected_board_ids([root.id, page.id, unrelated.id])

      expect(result).to eq(Set[root.id, page.id])
    end

    it "is empty for an empty batch" do
      expect(described_class.protected_board_ids([])).to eq(Set.new)
    end

    it "accepts Board records as well as ids" do
      printable

      expect(described_class.protected_board_ids([page])).to eq(Set[page.id])
    end
  end

  describe "#summary" do
    it "names the listing and the printable's root board" do
      printable

      summary = described_class.new(page).summary

      expect(summary[:role]).to eq(:page)
      expect(summary[:printables].first).to include(
        etsy_listing_id: 1234567890,
        root_board: { id: root.id, name: "Daily Routines" },
      )
    end

    it "is nil when nothing protects the board" do
      expect(described_class.new(unrelated).summary).to be_nil
    end
  end

  # A printable can carry several Etsy listings. Protection reads every one of
  # them and is never filtered on which are live: the paper a superseded listing
  # sold is still on someone's fridge.
  describe "with listing rows" do
    # The shape everything will look like once the scalar columns are gone.
    def listing_only_printable(**listing_attrs)
      printable = BoardPrintable.create!(
        board: root, status: "complete", board_ids: [root.id, page.id],
      )
      printable.etsy_listings.create!(**listing_attrs)
      printable
    end

    it "protects from a listing row alone, with no scalar columns set" do
      listing_only_printable(etsy_listing_id: 1234567890, state: "published",
                             published_at: 1.day.ago)

      expect(described_class.new(root).protected?).to be true
      expect(described_class.new(page).protected?).to be true
    end

    # Detaching is not a release. Release is the audited waiver, and nothing
    # else.
    it "keeps protecting after every listing is superseded" do
      listing_only_printable(etsy_listing_id: 1234567890, state: "superseded",
                             published_at: 2.days.ago, superseded_at: 1.day.ago)

      expect(described_class.new(root).protected?).to be true
    end

    # Allocating a row touches nothing external, so it must lock nothing —
    # otherwise drafting a second listing you never publish freezes the boards.
    it "does not protect from a pending row that never reached Etsy" do
      listing_only_printable(state: "pending")

      expect(described_class.new(root).protected?).to be false
    end

    it "does not protect from a failed row that never reached Etsy" do
      listing_only_printable(state: "failed", error: "Etsy said no")

      expect(described_class.new(root).protected?).to be false
    end

    # The frontend reads `etsy_listing_id` / `etsy_listing_url` off each
    # printable (MarketplacePrintable in src/data/marketplaceProtection.ts).
    # Those keys keep their meaning; the array is additive.
    describe "#summary with several listings" do
      it "reports the attached listing as the primary and carries them all" do
        printable = BoardPrintable.create!(
          board: root, status: "complete", board_ids: [root.id, page.id],
        )
        printable.etsy_listings.create!(
          etsy_listing_id: 111, etsy_listing_url: "https://www.etsy.com/listing/111",
          state: "superseded", published_at: 3.days.ago, superseded_at: 2.days.ago,
        )
        printable.etsy_listings.create!(
          etsy_listing_id: 222, etsy_listing_url: "https://www.etsy.com/listing/222",
          state: "published", published_at: 1.day.ago, purpose: "bundle", label: "holiday",
        )

        summary = described_class.new(root).summary[:printables].sole

        expect(summary[:etsy_listing_id]).to eq(222)
        expect(summary[:etsy_listing_url]).to eq("https://www.etsy.com/listing/222")
        expect(summary[:etsy_listings].map { |l| l[:etsy_listing_id] }).to contain_exactly(111, 222)
        expect(summary[:etsy_listings].find { |l| l[:etsy_listing_id] == 111 }[:superseded]).to be true
        expect(summary[:etsy_listings].find { |l| l[:etsy_listing_id] == 222 }[:purpose]).to eq("bundle")
      end

      # Nothing live to point at, but the paper still exists — the primary falls
      # back to the detached listing rather than reporting nothing.
      it "falls back to a superseded listing when none is attached" do
        printable = BoardPrintable.create!(
          board: root, status: "complete", board_ids: [root.id],
        )
        printable.etsy_listings.create!(
          etsy_listing_id: 333, state: "superseded",
          published_at: 3.days.ago, superseded_at: 1.day.ago,
        )

        expect(described_class.new(root).summary[:printables].sole[:etsy_listing_id]).to eq(333)
      end
    end
  end
end
