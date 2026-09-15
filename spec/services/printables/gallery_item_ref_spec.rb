require "rails_helper"

RSpec.describe Printables::GalleryItemRef do
  describe ".parse" do
    it "accepts a legacy slide and a styled slide" do
      legacy = described_class.parse("legacy:on_paper")
      styled = described_class.parse("styled:styled_hero")

      expect(legacy).to have_attributes(prefix: "legacy", variant: "on_paper", legacy?: true, styled?: false)
      expect(styled).to have_attributes(prefix: "styled", variant: "styled_hero", styled?: true)
      expect(styled.to_s).to eq("styled:styled_hero")
    end

    # An allowlist on both halves: a prefix it doesn't know is refused, and so is
    # a variant that exists under the OTHER prefix.
    it "refuses anything outside the allowlist" do
      ["photo:on_paper", "legacy:glossy", "legacy:styled_hero", "styled:on_paper", "on_paper", "", nil, 5]
        .each { |raw| expect(described_class.parse(raw)).to be_nil, "expected #{raw.inspect} to be refused" }
    end

    it "refuses a retired legacy variant" do
      expect(described_class.parse("legacy:#{BoardPrintable::IMAGE_COVER}")).to be_nil
    end
  end

  describe ".error_for" do
    # Reserved for the scene engine, which lands separately.
    it "refuses composition refs with a 'not yet' reason rather than a typo reason" do
      expect(described_class.error_for("composition:12")).to match(/can't be used yet/)
    end

    it "names the ref it refuses" do
      expect(described_class.error_for("legacy:glossy")).to include("legacy:glossy")
      expect(described_class.error_for("photo:x")).to match(/unknown kind/)
    end

    it "is nil for a valid ref" do
      expect(described_class.error_for("legacy:about")).to be_nil
    end
  end

  describe ".catalogue" do
    it "offers every legacy slide in rank order, then every styled slide" do
      expect(described_class.catalogue.map(&:to_s)).to eq(
        BoardPrintable::LISTING_IMAGE_ORDER.map { |v| "legacy:#{v}" } +
          BoardPrintable::STYLED_IMAGE_VARIANTS.map { |v| "styled:#{v}" },
      )
    end
  end

  describe "SUGGESTED" do
    it "fits Etsy's cap with no duplicates and only valid refs" do
      expect(described_class::SUGGESTED.size).to be <= described_class::MAX_ITEMS
      expect(described_class::SUGGESTED.uniq).to eq(described_class::SUGGESTED)
      expect(described_class::SUGGESTED).to all(satisfy { |raw| described_class.valid?(raw) })
    end

    # Rank 1 is the search thumbnail, and the shop audit says it belongs to a
    # photograph of the product in a room.
    it "leads with the photoreal paper mockup" do
      expect(described_class::SUGGESTED.first).to eq("legacy:#{BoardPrintable::IMAGE_ON_PAPER}")
    end

    # The styled slides replace their legacy twins; a buyer shouldn't see the
    # same slide twice.
    it "never pairs a styled slide with its legacy twin" do
      expect(described_class::SUGGESTED).not_to include("legacy:hero", "legacy:whats_included")
    end
  end

  describe "#resolve" do
    let(:board) { create(:board, user: create(:user)) }
    let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id]) }
    let(:listing) { printable.etsy_listings.create! }
    let(:other) { printable.etsy_listings.create! }
    let(:ref) { described_class.parse("legacy:on_paper") }

    it "is nil when nothing is rendered" do
      expect(ref.resolve(listing)).to be_nil
    end

    it "falls back to the shared blob" do
      printable.attach_image!(bytes: "shared", variant: "on_paper")

      expect(ref.resolve(listing.reload).download).to eq("shared")
      expect(ref.resolves_to_own?(listing)).to be false
    end

    it "prefers the listing's own blob, and never another listing's" do
      printable.attach_image!(bytes: "shared", variant: "on_paper")
      printable.attach_image!(bytes: "theirs", variant: "on_paper", listing: other)
      printable.attach_image!(bytes: "mine", variant: "on_paper", listing: listing)

      expect(ref.resolve(listing.reload).download).to eq("mine")
      expect(ref.resolves_to_own?(listing)).to be true
      expect(ref.resolve(printable.etsy_listings.create!).download).to eq("shared")
    end
  end
end
