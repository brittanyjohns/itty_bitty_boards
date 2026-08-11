require "rails_helper"

RSpec.describe Printables::IncludedItems do
  describe ".headline" do
    it "describes a single board by its page count" do
      expect(described_class.headline(board_count: 1, page_count: 6))
        .to eq("6-page board PDF — color + low-ink")
    end

    it "describes a set by board count AND page count, and says it's two files" do
      # A bundle ships every board twice and arrives as two PDFs; quoting one
      # page count understates a 9-board set badly.
      expect(described_class.headline(board_count: 9, page_count: 22))
        .to eq("9 boards, 22 pages — 2 PDFs (full color + low-ink)")
    end

    it "omits the page count rather than claiming zero pages" do
      expect(described_class.headline(board_count: 1, page_count: nil))
        .to eq("Board PDF — color + low-ink")
      expect(described_class.headline(board_count: 3, page_count: 0))
        .to eq("3 boards — 2 PDFs (full color + low-ink)")
    end
  end

  describe ".all" do
    # The phrase has to name the SPEAKING. "Free online version" reads as a PDF
    # viewer, and "voice output" is AAC jargon a parent shopping for their kid
    # doesn't parse — this list is read by both audiences.
    it "leads with the document line and names the audio companion" do
      items = described_class.all(board_count: 1, page_count: 6)

      expect(items.first).to eq("6-page board PDF — color + low-ink")
      expect(items).to include("Free audio companion — tap any word and it talks")
    end
  end
end
