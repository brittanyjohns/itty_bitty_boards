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
      named = create(:board, user: owner, name: "Feelings Vocabulary Board")
      title = described_class.new(
        BoardPrintable.create!(board: named, status: "complete", board_ids: [named.id]),
      ).build["title"]

      expect(title).to include("AAC Printable")
      expect(title).not_to include("AAC Vocabulary Board Printable")
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

  describe "tags" do
    it "fills all 13 slots with legal tags" do
      tags = build(topic: "farm animals")["tags"]

      expect(tags.length).to eq(Etsy::CopyRules::TAG_MAX)
      expect(tags.map(&:length).max).to be <= Etsy::CopyRules::TAG_LEN_MAX
      expect(tags.uniq).to eq(tags)
      expect(tags).to include("aac", "printable", "farm animals")
    end
  end

  describe "description" do
    it "opens with the brand lead and closes with the app footer" do
      description = build["description"]

      expect(description).to start_with(described_class::LEAD)
      expect(description).to end_with(described_class::FOOTER)
      expect(description).to include("WHAT'S INCLUDED")
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
