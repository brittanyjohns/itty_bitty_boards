require "rails_helper"

RSpec.describe Boards::AdminBuilder::PlanValidator do
  def tiles(*labels)
    labels.map { |label| { label: label, part_of_speech: "noun" } }
  end

  def validate(tiles:, columns: 2, rows: 2, allow_partial_row: false)
    described_class.new(tiles: tiles, columns: columns, rows: rows, allow_partial_row: allow_partial_row).call
  end

  it "accepts a plan that exactly fills the grid" do
    expect(validate(tiles: tiles("i", "want", "more", "help"))).to eq([])
  end

  describe "tile count" do
    it "rejects a short plan and says how many to add" do
      problems = validate(tiles: tiles("i", "want", "more"))
      expect(problems.first).to include("3 words for a 2×2 grid (needs exactly 4)")
      expect(problems.first).to include("Add 1")
    end

    it "allows a short plan when the partial-row escape hatch is ticked" do
      expect(validate(tiles: tiles("i", "want", "more"), allow_partial_row: true)).to eq([])
    end

    it "rejects an over-full plan even with the escape hatch ticked" do
      problems = validate(tiles: tiles("i", "want", "more", "help", "stop"), allow_partial_row: true)
      expect(problems.first).to include("won't fit")
      expect(problems.first).to include("Remove 1")
    end

    it "rejects an empty word list" do
      expect(validate(tiles: [])).to eq(["Add at least one word."])
    end

    it "rejects a grid with no columns or rows" do
      expect(validate(tiles: tiles("i"), columns: 0, rows: 2)).to eq(["Set both a column count and a row count."])
    end
  end

  describe "labels" do
    it "rejects a blank label" do
      plan = tiles("i", "want", "more") + [{ label: "", part_of_speech: "noun" }]
      expect(validate(tiles: plan)).to include(a_string_including("Every tile needs a word"))
    end

    it "rejects duplicate labels" do
      problems = validate(tiles: tiles("i", "want", "want", "help"))
      expect(problems).to include(a_string_including("Duplicate words: want"))
    end

    # images.label is a lowercase matching key, so "Want" and "want" resolve to
    # the same symbol — two cells spent on one tile.
    it "treats a casing-only difference as a duplicate" do
      problems = validate(tiles: tiles("i", "Want", "want", "help"))
      expect(problems).to include(a_string_including("Duplicate words: want"))
    end
  end

  describe "part of speech" do
    it "rejects a value outside the Fitzgerald key" do
      plan = tiles("i", "want", "more") + [{ label: "help", part_of_speech: "gerund" }]
      expect(validate(tiles: plan)).to include(a_string_including("Unknown part of speech: gerund"))
    end

    it "accepts every canonical value" do
      ColorHelper::PARTS_OF_SPEECH.each do |pos|
        problems = validate(tiles: [{ label: "word", part_of_speech: pos }], columns: 1, rows: 1)
        expect(problems).to eq([]), "expected #{pos} to be accepted"
      end
    end

    it "defaults a missing part of speech rather than rejecting it" do
      expect(validate(tiles: [{ label: "word" }], columns: 1, rows: 1)).to eq([])
    end
  end
end
