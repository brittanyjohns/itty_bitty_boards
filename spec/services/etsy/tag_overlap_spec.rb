require "rails_helper"

RSpec.describe Etsy::TagOverlap do
  let(:owner) { create(:user) }

  def printable(name, tags: nil)
    board = create(:board, user: owner, name: name)
    BoardPrintable.create!(
      board: board, status: "complete", board_ids: [board.id],
      listing_copy: tags ? { "tags" => tags } : {},
    )
  end

  BOILERPLATE = [
    "aac", "printable", "digital download", "communication board",
    "autism support", "slp", "classroom", "aac printable", "voice output aac",
    "speech therapy", "special education", "nonspeaking", "slp resources",
  ].freeze

  it "flags a printable whose tags are a near-duplicate of another's" do
    printable("Hair Salon", tags: BOILERPLATE)
    subject_printable = printable("Hospital Stay", tags: BOILERPLATE)

    overlap = described_class.new(subject_printable)

    expect(overlap).to be_any
    expect(overlap.matches.first.count).to eq(13)
    expect(overlap.matches.first.printable.board.name).to eq("Hair Salon")
    expect(overlap.matches.first.shared).to include("communication board")
  end

  it "stays quiet on a legitimately distinct pair" do
    printable("Hair Salon", tags: BOILERPLATE.first(7) + ["hair salon", "washing hair", "haircut", "barber shop", "salon words", "getting a haircut"])
    subject_printable = printable(
      "Hospital Stay",
      tags: BOILERPLATE.first(7) + ["hospital stay", "doctor visit", "feeling sick", "medical play", "nurse", "hospital words"],
    )

    expect(described_class.new(subject_printable)).not_to be_any
  end

  it "ignores printables that have no saved listing copy" do
    printable("Hair Salon")
    subject_printable = printable("Hospital Stay", tags: BOILERPLATE)

    expect(described_class.new(subject_printable)).not_to be_any
  end

  it "never compares a printable against itself" do
    subject_printable = printable("Hospital Stay", tags: BOILERPLATE)

    expect(described_class.new(subject_printable)).not_to be_any
  end

  it "compares the tags it is handed rather than the saved ones" do
    printable("Hair Salon", tags: BOILERPLATE)
    subject_printable = printable("Hospital Stay", tags: ["hospital stay"])

    expect(described_class.new(subject_printable, tags: BOILERPLATE)).to be_any
  end

  # The acceptance criterion for making `topic` editable after creation: the
  # warning exists to catch listings that don't describe themselves, and a topic
  # is the only thing that can fix one. Two printables that each say what they
  # are must stop colliding — otherwise the control is theatre.
  describe "a topic set after creation" do
    def with_topic(name, topic)
      board = create(:board, user: owner, name: name)
      p = BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], topic: topic)
      p.regenerate_listing_copy!
      p
    end

    it "silences the warning between two printables that describe themselves" do
      with_topic("Hospital Words", "hospital stay, doctor visit, medical vocabulary, nurse words")
      subject_printable = with_topic("Playground Words", "playground, outdoor play, park vocabulary, swing words")

      expect(described_class.new(subject_printable)).not_to be_any
    end

    # The boundary, and the reason MIN_TOPIC_TAGS is derived rather than a
    # number in the hint text. Every pool but `topic` is shared, and the
    # shortfall is topped up from the same ORDERED list — so a short topic
    # collides twice over, and three phrases lands exactly on the threshold.
    it "still warns when each topic yields one tag fewer than the minimum" do
      short = Etsy::TagOverlap::MIN_TOPIC_TAGS - 1
      with_topic("Hospital Words", Array.new(short) { |i| "hospital word #{i}" }.join(", "))
      subject_printable = with_topic("Playground Words", Array.new(short) { |i| "park word #{i}" }.join(", "))

      overlap = described_class.new(subject_printable)
      expect(overlap).to be_any
      expect(overlap.matches.first.count).to eq(Etsy::CopyRules::TAG_MAX - short)
    end

    it "stops warning at exactly MIN_TOPIC_TAGS" do
      enough = Etsy::TagOverlap::MIN_TOPIC_TAGS
      with_topic("Hospital Words", Array.new(enough) { |i| "hospital word #{i}" }.join(", "))
      subject_printable = with_topic("Playground Words", Array.new(enough) { |i| "park word #{i}" }.join(", "))

      expect(described_class.new(subject_printable)).not_to be_any
    end

    # The failure the reordering fixed: with nothing topical to say, the generic
    # pools fill all 13 slots identically.
    it "still warns when neither has a topic" do
      first = create(:board, user: owner, name: "No Topic One")
      second = create(:board, user: owner, name: "No Topic Two")
      [first, second].each do |board|
        BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
                      .regenerate_listing_copy!
      end

      subject_printable = BoardPrintable.order(:id).last
      expect(described_class.new(subject_printable)).to be_any
    end

    it "puts the topic's own tags ahead of the generic pools" do
      p = with_topic("Hospital Words", "hospital stay, doctor visit")

      tags = p.listing_copy["tags"]
      expect(tags).to include("hospital stay", "doctor visit")
      # always_on is three, then topic — so a topic tag can never be crowded out.
      expect(tags.index("hospital stay")).to be < tags.index("communication board")
    end
  end

  it "shows the worst collision first and caps how many it lists" do
    4.times { |i| printable("Clone #{i}", tags: BOILERPLATE) }
    near = printable("Near Miss", tags: BOILERPLATE.first(11) + ["hair salon", "washing hair"])
    subject_printable = printable("Hospital Stay", tags: BOILERPLATE)

    matches = described_class.new(subject_printable).matches

    expect(matches.size).to eq(described_class::MAX_MATCHES)
    expect(matches.map(&:count)).to eq(matches.map(&:count).sort.reverse)
    expect(matches.map(&:printable)).not_to include(near)
  end

  # The collision most worth catching, and the one the printable-level check
  # could not see: two listings for the SAME product share everything but their
  # topic tags by construction, and Etsy caps how many of one shop's results
  # appear per query — so a bundle listed beside its standalone can bury it.
  describe "sibling listings on the same printable" do
    it "warns when a second listing shares the tag set" do
      board = create(:board, name: "Core Words")
      printable = BoardPrintable.create!(
        board: board, status: "complete",
        listing_copy: { "title" => "T", "tags" => Etsy::CopyRules::TAG_MAX.times.map { |i| "tag#{i}" } },
      )
      printable.etsy_listings.create!(purpose: "standalone")
      bundle = printable.etsy_listings.create!(purpose: "bundle", label: "holiday")

      overlap = described_class.new(bundle)

      expect(overlap.any?).to be true
      expect(overlap.matches.first.label).to include("holiday").or include("standalone")
      expect(overlap.matches.first.printable).to eq(printable)
    end

    it "does not warn about itself" do
      board = create(:board, name: "Core Words")
      printable = BoardPrintable.create!(
        board: board, status: "complete",
        listing_copy: { "title" => "T", "tags" => Etsy::CopyRules::TAG_MAX.times.map { |i| "tag#{i}" } },
      )
      only = printable.etsy_listings.create!

      expect(described_class.new(only).any?).to be false
    end
  end
end
