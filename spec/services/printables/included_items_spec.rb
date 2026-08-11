require "rails_helper"

RSpec.describe Printables::IncludedItems do
  describe ".headline" do
    it "describes a single board by its page count" do
      expect(described_class.headline(board_count: 1, page_count: 6))
        .to eq("6-page board PDF — color, low-ink + trim-ready")
    end

    it "describes a set by board count AND page count, and says it's three files" do
      # A bundle ships every board three times and arrives as three PDFs;
      # quoting one page count understates a 9-board set badly.
      expect(described_class.headline(board_count: 9, page_count: 33))
        .to eq("9 boards, 33 pages — 3 PDFs (full color + low-ink + trim-ready)")
    end

    it "omits the page count rather than claiming zero pages" do
      expect(described_class.headline(board_count: 1, page_count: nil))
        .to eq("Board PDF — color, low-ink + trim-ready")
      expect(described_class.headline(board_count: 3, page_count: 0))
        .to eq("3 boards — 3 PDFs (full color + low-ink + trim-ready)")
    end

    # Every headline lands in a fixed-height band on a 1280px slide, where copy
    # that outgrows its slot overlaps the next one rather than wrapping.
    it "stays inside the slide's bullet budget" do
      [
        described_class.headline(board_count: 25, page_count: 130),
        described_class.headline(board_count: 1, page_count: 7),
      ].each do |line|
        expect(line.length).to be <= Printables::SlideCopy::MAX_BULLET_LENGTH
      end
    end
  end

  describe ".all" do
    # The phrase has to name the SPEAKING. "Free online version" reads as a PDF
    # viewer, and "voice output" is AAC jargon a parent shopping for their kid
    # doesn't parse — this list is read by both audiences.
    it "leads with the document line and names the audio companion" do
      items = described_class.all(board_count: 1, page_count: 6)

      expect(items.first).to eq("6-page board PDF — color, low-ink + trim-ready")
      expect(items).to include("Free audio companion — tap any word and it talks")
    end
  end
end
