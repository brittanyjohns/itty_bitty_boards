require "rails_helper"

RSpec.describe Etsy::ListingCopy do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "core words") }

  # page_count 7 is what a one-board printable really merges to: cover,
  # how-to-use, the three board pages, license, credits. The copy must quote
  # the three, so a fixture that agreed with it would prove nothing.
  def printable(**attrs)
    BoardPrintable.create!(
      { board: board, status: "complete", board_ids: [board.id], page_count: 7 }.merge(attrs),
    )
  end

  def build(**attrs) = described_class.new(printable(**attrs)).build

  describe "title" do
    it "stays within Etsy's cap and carries the digital-download suffix" do
      title = build["title"]
      expect(title.length).to be <= Etsy::CopyRules::TITLE_MAX
      expect(title).to end_with("(Digital Download)")
    end

    it "never carries more than one ampersand" do
      long_board = create(:board, user: owner, name: "Farm & Zoo")
      title = described_class.new(
        BoardPrintable.create!(board: long_board, status: "complete", board_ids: [long_board.id]),
      ).build["title"]

      expect(title.count("&")).to be <= 1
    end

    it "shrinks the product decoration when the board already names it" do
      named = create(:board, user: owner, name: "Feelings Communication Board")
      title = described_class.new(
        BoardPrintable.create!(board: named, status: "complete", board_ids: [named.id]),
      ).build["title"]

      expect(title).to include("AAC Printable")
      expect(title).not_to include("AAC Communication Board Printable")
    end

    it "names the product when the board's own name doesn't" do
      expect(build["title"]).to include("AAC Communication Board Printable")
    end

    # A blank topic used to collapse the title ladder onto its bare
    # "N-Board Set" rung; the mined board names widen it again.
    it "widens a set's title with the sub-board vocabulary when no topic was typed" do
      title = described_class.new(
        set_printable("Bath Time", ["At the Sink", "Getting Dry"]),
      ).build["title"]

      expect(title).to include("Getting Dry")
    end

    it "falls back to a form that fits rather than truncating a long board name mid-word" do
      wordy = create(:board, user: owner, name: ("Snack Time " * 14).strip)
      title = described_class.new(
        BoardPrintable.create!(board: wordy, status: "complete", board_ids: [wordy.id]),
      ).build["title"]

      expect(title.length).to be <= Etsy::CopyRules::TITLE_MAX
      expect(title).not_to include("for Speech The")
    end
  end

  # A printable over a board tree, so the sub-board names are available as
  # topical vocabulary. Nothing sets `topic` — that's the real-world case: it's
  # an optional field and it was blank on all nine listings.
  def set_printable(root_name, sub_names)
    root = create(:board, user: owner, name: root_name)
    subs = sub_names.map { |name| create(:board, user: owner, name: name) }
    BoardPrintable.create!(
      board: root, status: "complete", include_subboards: true,
      board_ids: [root.id, *subs.map(&:id)], page_count: 7,
    )
  end

  describe "tags" do
    it "fills all 13 slots with legal tags" do
      tags = build(topic: "farm animals")["tags"]

      expect(tags.length).to eq(Etsy::CopyRules::TAG_MAX)
      expect(tags.map(&:length).max).to be <= Etsy::CopyRules::TAG_LEN_MAX
      expect(tags.uniq).to eq(tags)
      expect(tags).to include("aac", "printable", "farm animals")
    end

    # The one that would have caught it: nine printables published to Etsy in
    # Aug 2026 carried IDENTICAL 13-tag sets, so they cannibalized each other's
    # search results and not one tag described the product. The generic pools
    # filled every slot before the per-product vocabulary was ever consulted.
    it "gives two printables on different subjects materially different tags" do
      hospital = described_class.new(set_printable(
        "Hospital Stay", ["Getting Admitted", "Doctor Visit", "Feeling Sick", "Hospital Food", "Going Home"],
      )).build["tags"]
      salon = described_class.new(set_printable(
        "Hair Salon", ["Washing Hair", "Getting a Haircut", "Choosing a Style", "Blow Dry", "Paying"],
      )).build["tags"]

      expect((hospital - salon).length).to be >= 5
      expect(hospital).to include("hospital stay", "doctor visit")
      expect(salon).to include("hair salon", "washing hair")
    end

    it "mines the sub-board names when no topic was typed" do
      tags = described_class.new(set_printable("Bath Time", ["At the Sink", "Getting Dry"])).build["tags"]

      expect(tags).to include("bath time", "at the sink", "getting dry")
      # Below always_on, above the shared boilerplate.
      expect(tags.index("at the sink")).to be < tags.index("communication board")
    end

    it "keeps an authored topic ahead of the mined board names" do
      root = create(:board, user: owner, name: "Hospital Stay")
      sub = create(:board, user: owner, name: "Doctor Visit")
      tags = described_class.new(BoardPrintable.create!(
        board: root, status: "complete", include_subboards: true,
        board_ids: [root.id, sub.id], topic: "medical vocabulary",
      )).build["tags"]

      expect(tags).to include("medical vocabulary")
      expect(tags).not_to include("doctor visit")
    end

    # The shared boilerplate is still correct for a printable with nothing
    # topical to say — this pins it so a future reshuffle of the pools is a
    # deliberate act, not a surprise.
    it "yields the stable boilerplate set for a single board with no topic" do
      expect(build["tags"]).to eq([
        "aac", "printable", "digital download",
        "communication board",
        "autism support", "slp", "classroom",
        "aac printable", "voice output aac", "speech therapy", "special education",
        "nonspeaking", "slp resources",
      ])
    end

    it "caps a wordy topic rather than letting it take the whole listing" do
      tags = build(topic: (1..12).map { |i| "topic phrase #{i}" }.join(", "))["tags"]

      expect(tags.count { |t| t.start_with?("topic phrase") }).to eq(Etsy::CopyRules::TOPIC_TAG_MAX)
      expect(tags).to include("communication board", "autism support")
    end

    it "keeps the proven search terms for a topic of ordinary length" do
      tags = build(topic: "hospital stay, doctor visit")["tags"]

      expect(tags).to include("hospital stay", "communication board", "speech therapy")
    end
  end

  describe "description" do
    it "opens with the brand lead and closes with the app footer" do
      description = build["description"]

      expect(description).to start_with(described_class.lead(qualifier: " for Core Words"))
      expect(description).to end_with(described_class::FOOTER)
      expect(description).to include("WHAT'S INCLUDED")
    end

    # The opener is the text Google indexes and the only description a buyer
    # reads above the fold. Nine listings shipped with it identical.
    it "works the topic into the opening sentence" do
      description = build(topic: "hospital stays")["description"]

      expect(description).to start_with(
        "Give every voice a way to be heard with this Printable Communication Board for " \
        "Hospital Stays from SpeakAnyWay.",
      )
    end

    it "keeps the original opener when the subject only repeats the product" do
      named = create(:board, user: owner, name: "Feelings Communication Board")
      description = described_class.new(
        BoardPrintable.create!(board: named, status: "complete", board_ids: [named.id]),
      ).build["description"]

      expect(description).to start_with(described_class.lead)
    end

    # Prose says "free audio companion" while the tags keep "voice output aac"
    # — a deliberate split, and a buyer reads the description, not the tags.
    it "names the audio companion in the buyer's words, not the tag pool's" do
      expect(build["description"]).to include("free audio companion")
      expect(build["description"]).not_to include("voice output aac")
    end

    it "names each board in a set rather than quoting a page count" do
      other = create(:board, user: owner, name: "feelings")
      description = build(board_ids: [board.id, other.id], include_subboards: true)["description"]

      expect(description).to include("THE 2 BOARDS")
      expect(description).to include("Core Words", "Feelings")
      expect(description).to include("2 boards, 6 pages — 3 PDFs (full color + low-ink + trim-ready)")
    end

    # The cover, how-to-use, license and credits pages are not what a buyer is
    # counting — three board pages is the product.
    it "counts board pages, not the wrapper pages around them" do
      expect(build["description"]).to include("3-page board PDF — color, low-ink + trim-ready")
      expect(build["description"]).not_to include("7-page")
    end

    it "omits the boards section for a single-board printable" do
      expect(build["description"]).not_to include("THE 1 BOARDS")
    end
  end

  describe "summary" do
    it "stays under the summary cap" do
      wordy = create(:board, user: owner, name: "x" * 300)
      summary = described_class.new(
        BoardPrintable.create!(board: wordy, status: "complete", board_ids: [wordy.id]),
      ).build["summary"]

      expect(summary.length).to be <= described_class::SUMMARY_MAX
    end
  end

  it "defaults the price to what the printables pipeline actually ships" do
    expect(build["price_cents"]).to eq(500)
  end
end
