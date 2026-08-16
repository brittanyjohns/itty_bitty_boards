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

  it "shows the worst collision first and caps how many it lists" do
    4.times { |i| printable("Clone #{i}", tags: BOILERPLATE) }
    near = printable("Near Miss", tags: BOILERPLATE.first(11) + ["hair salon", "washing hair"])
    subject_printable = printable("Hospital Stay", tags: BOILERPLATE)

    matches = described_class.new(subject_printable).matches

    expect(matches.size).to eq(described_class::MAX_MATCHES)
    expect(matches.map(&:count)).to eq(matches.map(&:count).sort.reverse)
    expect(matches.map(&:printable)).not_to include(near)
  end
end
