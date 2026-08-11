require "rails_helper"

RSpec.describe Boards::Printables::ContentTilePlan do
  let(:owner) { create(:user) }

  def boards(count, name: "Board")
    Array.new(count) { |i| build(:board, user: owner, name: "#{name} #{i}", id: i + 1) }
  end

  describe "the tile cap" do
    it "never plans more tiles than it can render legibly" do
      plan = described_class.build(boards: boards(20))

      expect(plan.tiles.size).to eq(described_class::MAX_TILES)
    end

    it "keeps the boards in the order it was given, root first" do
      given = boards(4)

      plan = described_class.build(boards: given)

      expect(plan.boards.map(&:name)).to eq(given.map(&:name))
    end

    it "plans nothing for no boards rather than raising" do
      plan = described_class.build(boards: [])

      expect(plan.any?).to be(false)
      expect(plan.tiles).to be_empty
    end
  end

  describe "columns" do
    # Small sets stay a single row so their tiles render large; past three the
    # grid wraps to two rows and never more.
    {1 => 1, 2 => 2, 3 => 3, 4 => 2, 5 => 3, 6 => 3, 7 => 4, 8 => 4}.each do |count, columns|
      it "lays #{count} tiles out in #{columns} column(s)" do
        plan = described_class.build(boards: boards(count))

        expect(plan.columns).to eq(columns)
        expect((plan.tiles.size.to_f / plan.columns).ceil).to be <= 2
      end
    end
  end

  # Every grid cell needs a definite height for the page card inside it to size
  # itself against; an auto row is what let the cards overflow and get clipped.
  describe "rows" do
    {1 => 1, 3 => 1, 4 => 2, 6 => 2, 8 => 2}.each do |count, rows|
      it "plans #{rows} row(s) for #{count} tiles" do
        expect(described_class.build(boards: boards(count)).rows).to eq(rows)
      end
    end

    it "never plans zero rows, even with nothing to lay out" do
      expect(described_class.build(boards: []).rows).to eq(1)
    end
  end

  describe "the overflow caption" do
    # Low-ink has its own slide now, so it is no longer sold in this caption —
    # the caption counts boards the grid couldn't fit, and nothing else.
    it "says nothing when every board is already shown" do
      plan = described_class.build(boards: boards(3))

      expect(plan.overflow_note).to be_nil
    end

    it "counts only the pages the grid withheld" do
      plan = described_class.build(boards: boards(12))

      expect(plan.overflow_note).to eq("+4 more pages")
    end

    it "uses the singular for a single withheld page" do
      plan = described_class.build(boards: boards(9), max_tiles: 8)

      expect(plan.overflow_note).to eq("+1 more page")
    end
  end

  # The cards are a uniform shape so the row can't come out ragged, which means
  # height follows from width — the width cap is what keeps a row of one or two
  # boards from outgrowing its slot.
  describe "the card width cap" do
    it "gives a sparse row bigger cards than a full one" do
      one = described_class.build(boards: boards(1)).tile_max_px
      four = described_class.build(boards: boards(4)).tile_max_px
      eight = described_class.build(boards: boards(8)).tile_max_px

      expect(one).to be > four
      expect(four).to be > eight
    end

    it "caps an empty plan rather than returning nil" do
      expect(described_class.build(boards: []).tile_max_px).to be_positive
    end
  end

  describe "labels" do
    it "title-cases board names so the grid reads as a table of contents" do
      plan = described_class.build(boards: [build(:board, user: owner, name: "core words", id: 1)])

      expect(plan.tiles.first.label).to eq("Core Words")
      expect(plan.labels?).to be(true)
    end

    # An empty caption band under a tile is worse than no band at all — it
    # reads as a rendering bug on a listing image.
    it "treats a blank board name as no label" do
      plan = described_class.build(boards: [build(:board, user: owner, name: "   ", id: 1)])

      expect(plan.tiles.first.label).to be_nil
      expect(plan.labels?).to be(false)
    end
  end
end
