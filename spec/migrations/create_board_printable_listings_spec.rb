require "rails_helper"
require Rails.root.join("db/migrate/20260820120000_create_board_printable_listings.rb")

# Only the BACKFILL is exercised here — `create_table` has already run against
# the test schema. The backfill is the part that can go wrong quietly: every
# board that was protected before this migration must still be protected after
# it, whichever of the three legacy column shapes its printable carries.
RSpec.describe CreateBoardPrintableListings do
  let(:migration) { described_class.new }
  let(:user) { FactoryBot.create(:user) }
  let(:root) { FactoryBot.create(:board, user: user, name: "Daily Routines") }
  let(:page) { FactoryBot.create(:board, user: user, name: "Snack Time") }

  # Written with update_columns so the row reproduces the historical shape
  # exactly, without any of today's writers normalizing it.
  def legacy_printable(listing_id:, published_at:, **columns)
    printable = BoardPrintable.create!(
      board: root, status: "complete", board_ids: [root.id, page.id],
    )
    printable.update_columns(
      etsy_listing_id: listing_id,
      etsy_listing_url: listing_id && "https://www.etsy.com/listing/#{listing_id}",
      etsy_published_at: published_at,
      **columns,
    )
    printable
  end

  before { migration.verbose = false }

  def backfill! = migration.send(:backfill!)

  describe "a printable with an id and a timestamp" do
    it "becomes one published listing row carrying the id" do
      printable = legacy_printable(listing_id: 111, published_at: 3.days.ago)

      backfill!

      listing = printable.etsy_listings.sole
      expect(listing.etsy_listing_id).to eq(111)
      expect(listing.etsy_listing_url).to eq("https://www.etsy.com/listing/111")
      expect(listing.state).to eq("published")
      expect(listing.published_at).to be_present
      expect(listing.superseded_at).to be_nil
    end
  end

  # The shape the watermark exists for. Protection used to read the id column
  # directly; once that column is dropped the timestamp is the only evidence
  # left, so the backfill has to create it.
  describe "a printable with an id but NO timestamp" do
    it "becomes a published listing row AND gets the watermark stamped" do
      printable = legacy_printable(listing_id: 222, published_at: nil)

      backfill!

      expect(printable.etsy_listings.sole.etsy_listing_id).to eq(222)
      expect(printable.reload.etsy_published_at).to be_present
    end
  end

  # A relisted printable: #relist! NULLed the id and kept the timestamp. The
  # draft it was detached from is still on Etsy and its id is unrecoverable —
  # the row records that honestly rather than pretending there was no listing.
  describe "a printable with a timestamp but NO id" do
    it "becomes a superseded listing row with no id and a label saying why" do
      printable = legacy_printable(listing_id: nil, published_at: 5.days.ago)

      backfill!

      listing = printable.etsy_listings.sole
      expect(listing.etsy_listing_id).to be_nil
      expect(listing.state).to eq("superseded")
      expect(listing.superseded_at).to be_present
      expect(listing.label).to include("Etsy id was not recorded")
    end
  end

  it "copies the video stamp and the error across" do
    printable = legacy_printable(
      listing_id: 333, published_at: 2.days.ago,
      etsy_video_pushed_at: 1.day.ago, etsy_error: "something went wrong",
    )

    backfill!

    listing = printable.etsy_listings.sole
    expect(listing.video_pushed_at).to be_present
    expect(listing.error).to eq("something went wrong")
  end

  it "leaves a printable that never reached Etsy alone" do
    printable = legacy_printable(listing_id: nil, published_at: nil)

    backfill!

    expect(printable.etsy_listings).to be_empty
  end

  # The acceptance criterion for the whole migration. Protection is allowed to
  # widen and never to narrow, so this asserts on every legacy shape at once —
  # including the interior page, which is the half a naive backfill drops.
  describe "marketplace protection" do
    [
      ["an id and a timestamp", 444, -> { 3.days.ago }],
      ["an id but no timestamp", 555, -> { nil }],
      ["a timestamp but no id", nil, -> { 3.days.ago }],
    ].each do |description, listing_id, published_at|
      it "is unchanged for a printable with #{description}" do
        legacy_printable(listing_id: listing_id, published_at: published_at.call)
        expect(Boards::MarketplaceProtection.new(root).protected?).to be true

        backfill!

        expect(Boards::MarketplaceProtection.new(root).protected?).to be true
        expect(Boards::MarketplaceProtection.new(page).protected?).to be true
      end
    end

    it "does not start protecting a printable that never reached Etsy" do
      legacy_printable(listing_id: nil, published_at: nil)

      backfill!

      expect(Boards::MarketplaceProtection.new(root).protected?).to be false
    end
  end
end
