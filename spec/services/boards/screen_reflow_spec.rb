require "rails_helper"

RSpec.describe Boards::ScreenReflow do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  before do
    # 12-col lg, proportional md/sm (8 and 4) so we test a real narrowing.
    board.update_columns(large_screen_columns: 12, medium_screen_columns: 8, small_screen_columns: 4)
  end

  # A tile with an explicit lg cell (callbacks bypassed so x/y/w/h are exact).
  def tile(label, x:, y:, position:, w: 1, h: 1)
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => w, "h" => h } })
    bi
  end

  def cells(screen)
    board.board_images.map { |bi| bi.reload.layout[screen] }.compact
  end

  # Assert a screen's layout fits `columns`, never overlaps, and covers every tile.
  def expect_valid_layout(screen, columns, tile_count)
    placed = cells(screen)
    expect(placed.size).to eq(tile_count) # no tiles dropped

    occupied = []
    placed.each do |c|
      x = c["x"]; y = c["y"]; w = c["w"]; h = c["h"]
      expect(x).to be >= 0
      expect(x + w).to be <= columns # in-bounds (no overflow)
      h.times do |dy|
        w.times do |dx|
          cell = [x + dx, y + dy]
          expect(occupied).not_to include(cell) # no overlap
          occupied << cell
        end
      end
    end
  end

  describe ".reflow!" do
    it "writes clean, non-overlapping, in-bounds md and sm layouts for every tile" do
      14.times { |i| tile("w#{i}", x: i % 12, y: i / 12, position: i) }

      described_class.reflow!(board)

      expect_valid_layout("md", 8, 14)
      expect_valid_layout("sm", 4, 14)
    end

    it "keeps multi-width tiles inside the narrower grids instead of overflowing" do
      # Three w=3 tiles in lg's first row would be 9 wide — fine on lg(12),
      # overflowing on sm(4) unless reflowed.
      tile("a", x: 0, y: 0, position: 0, w: 3)
      tile("b", x: 3, y: 0, position: 1, w: 3)
      tile("c", x: 6, y: 0, position: 2, w: 3)

      described_class.reflow!(board)

      cells("sm").each { |c| expect(c["x"] + c["w"]).to be <= 4 }
      expect_valid_layout("sm", 4, 3)
    end

    it "never modifies the authored lg layout" do
      keep = tile("keep", x: 5, y: 2, position: 0, w: 2, h: 1)

      described_class.reflow!(board)

      expect(keep.reload.layout["lg"]).to include("x" => 5, "y" => 2, "w" => 2, "h" => 1)
    end

    it "mirrors the sm layout onto xs and xxs" do
      tile("a", x: 0, y: 0, position: 0)
      tile("b", x: 1, y: 0, position: 1)

      described_class.reflow!(board)

      board.board_images.each do |bi|
        bi.reload
        expect(bi.layout["xs"]).to eq(bi.layout["sm"])
        expect(bi.layout["xxs"]).to eq(bi.layout["sm"])
      end
    end

    it "preserves lg reading order when reflowing (row-major)" do
      first  = tile("first",  x: 0, y: 0, position: 5)
      second = tile("second", x: 1, y: 0, position: 9)
      third  = tile("third",  x: 0, y: 1, position: 2)

      described_class.reflow!(board)

      # On sm the three single-width tiles read left-to-right then down by lg order.
      expect(first.reload.layout["sm"]).to include("x" => 0, "y" => 0)
      expect(second.reload.layout["sm"]).to include("x" => 1, "y" => 0)
      expect(third.reload.layout["sm"]).to include("x" => 2, "y" => 0)
    end

    it "resyncs the denormalized board.layout for md and sm" do
      tile("a", x: 0, y: 0, position: 0)

      described_class.reflow!(board)
      board.reload

      expect(board.layout["md"]).to be_present
      expect(board.layout["sm"]).to be_present
    end

    it "is a no-op for an empty board" do
      expect(described_class.reflow!(board)).to eq([])
    end

    it "can narrow the screens it rewrites" do
      tile("a", x: 0, y: 0, position: 0)

      expect(described_class.reflow!(board, screens: ["sm"])).to eq(["sm"])
    end

    it "does not persist when dry_run is true" do
      bi = tile("a", x: 7, y: 0, position: 0)

      described_class.reflow!(board, dry_run: true)

      # The stored sm cell still mirrors the untouched authored x (no reflow saved).
      expect(bi.reload.layout["sm"]).to be_nil
    end
  end
end
