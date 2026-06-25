require "rails_helper"

RSpec.describe Boards::LayoutRepacker do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  before { board.update_column(:large_screen_columns, 12) }

  # Create a tile with an explicit lg layout (bypassing callbacks so the stored
  # x/y is exactly what we set — including deliberately out-of-grid positions).
  def tile(label, x:, y:, position:, w: 1, h: 1)
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => w, "h" => h } })
    bi
  end

  def lg(bi)
    bi.reload.layout["lg"]
  end

  describe ".repack!" do
    it "moves an out-of-grid tile inside the configured columns" do
      tile("I", x: 0, y: 0, position: 0)
      over = tile("More", x: 13, y: 1, position: 1) # past the 12-col grid

      moved = described_class.repack!(board)

      expect(moved).to eq(1)
      cell = lg(over)
      expect(cell["x"] + cell["w"]).to be <= 12
    end

    it "leaves authored in-grid tiles exactly where they are" do
      keep = tile("I", x: 0, y: 0, position: 0)
      tile("More", x: 13, y: 1, position: 1)

      described_class.repack!(board)

      expect(lg(keep)).to include("x" => 0, "y" => 0)
    end

    it "drops the overflow tile to a new row below the fitting tiles" do
      tile("I", x: 0, y: 0, position: 0)
      over = tile("More", x: 13, y: 0, position: 1) # same stored row, but off-grid

      described_class.repack!(board)

      expect(lg(over)["y"]).to be > 0
    end

    it "is a no-op on a board whose tiles already fit, returning 0" do
      a = tile("I", x: 0, y: 0, position: 0)
      b = tile("you", x: 11, y: 0, position: 1)

      expect(described_class.repack!(board)).to eq(0)
      expect(lg(a)).to include("x" => 0, "y" => 0)
      expect(lg(b)).to include("x" => 11, "y" => 0)
    end

    it "clamps a tile wider than the grid down to the column count" do
      board.update_column(:large_screen_columns, 4)
      wide = tile("banner", x: 2, y: 0, position: 0, w: 6) # spans to 8 on a 4-col grid

      described_class.repack!(board)

      cell = lg(wide)
      expect(cell["w"]).to be <= 4
      expect(cell["x"] + cell["w"]).to be <= 4
    end

    it "dry_run reports the move count without persisting" do
      tile("I", x: 0, y: 0, position: 0)
      over = tile("More", x: 13, y: 1, position: 1)

      expect(described_class.repack!(board, dry_run: true)).to eq(1)
      expect(lg(over)).to include("x" => 13) # untouched
    end

    it "resyncs the board's denormalized layout after repacking" do
      tile("I", x: 0, y: 0, position: 0)
      over = tile("More", x: 13, y: 1, position: 1)

      described_class.repack!(board)

      board.reload
      stored = board.layout["lg"][over.id.to_s]
      expect(stored["x"] + stored["w"]).to be <= 12
    end
  end
end
