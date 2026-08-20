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
end
