require "rails_helper"

RSpec.describe Etsy::TitlePrefixOverlap do
  let(:owner) { create(:user) }

  def printable(name, title:)
    board = create(:board, user: owner, name: name)
    BoardPrintable.create!(
      board: board, status: "complete", board_ids: [board.id],
      listing_copy: { "title" => title },
    )
  end

  it "flags a printable whose title shares the truncation prefix with another's" do
    printable("Recess", title: "AAC Communication Board Printable, Recess and Playground Set")
    subject_printable = printable("Haircut", title: "AAC Communication Board Printable, Haircut and Salon Visits")

    overlap = described_class.new(subject_printable)

    expect(overlap).to be_any
    expect(overlap.matches.first.printable.board.name).to eq("Recess")
  end

  it "stays quiet when the board name lands inside the prefix window" do
    printable("Recess", title: "AAC Recess Communication Board Printable")
    subject_printable = printable("Haircut", title: "AAC Haircut Communication Board Printable")

    expect(described_class.new(subject_printable)).not_to be_any
  end

  it "ignores printables with no saved title" do
    printable("Recess", title: nil)
    subject_printable = printable("Haircut", title: "AAC Communication Board Printable, Haircut Set")

    expect(described_class.new(subject_printable)).not_to be_any
  end

  it "never compares a printable against itself" do
    subject_printable = printable("Haircut", title: "AAC Communication Board Printable, Haircut Set")

    expect(described_class.new(subject_printable)).not_to be_any
  end

  it "compares the title it is handed rather than the saved one" do
    printable("Recess", title: "AAC Communication Board Printable, Recess and Playground Set")
    subject_printable = printable("Haircut", title: "AAC Haircut Communication Board Printable")

    overlap = described_class.new(subject_printable, title: "AAC Communication Board Printable, Haircut Set")

    expect(overlap).to be_any
  end

  it "is case-insensitive" do
    printable("Recess", title: "aac communication board printable, recess set")
    subject_printable = printable("Haircut", title: "AAC COMMUNICATION BOARD PRINTABLE, HAIRCUT SET")

    expect(described_class.new(subject_printable)).to be_any
  end

  describe "sibling listings on the same printable" do
    it "warns when a second listing shares the title prefix" do
      board = create(:board, name: "Core Words")
      printable = BoardPrintable.create!(
        board: board, status: "complete",
        listing_copy: { "title" => "AAC Communication Board Printable, Core Words Set" },
      )
      printable.etsy_listings.create!(purpose: "standalone")
      bundle = printable.etsy_listings.create!(purpose: "bundle", label: "holiday")

      overlap = described_class.new(bundle)

      expect(overlap.any?).to be true
      expect(overlap.matches.first.label).to include("holiday").or include("standalone")
      expect(overlap.matches.first.printable).to eq(printable)
    end

    it "does not warn when comparing the printable itself against a single non-overriding listing" do
      board = create(:board, name: "Core Words")
      printable = BoardPrintable.create!(
        board: board, status: "complete",
        listing_copy: { "title" => "AAC Communication Board Printable, Core Words Set" },
      )
      printable.etsy_listings.create!(purpose: "standalone")

      overlap = described_class.new(printable, title: printable.listing_copy_or_default["title"])

      expect(overlap.any?).to be false
    end
  end
end
