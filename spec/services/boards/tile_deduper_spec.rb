require "rails_helper"

RSpec.describe Boards::TileDeduper do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  # Each tile gets its OWN Image row that happens to share the label — the real
  # "all done" duplicate pointed at two distinct same-label images. BoardImage's
  # set_defaults derives the tile label from its image, so the image label is
  # what makes two tiles count as duplicates.
  def tile(label, position:, predictive_board_id: nil)
    create(:board_image, board: board, position: position,
                         predictive_board_id: predictive_board_id,
                         image: create(:image, label: label, user_id: user.id))
  end

  describe ".collapse_duplicates!" do
    it "removes the appended duplicate word tile, keeping the authored-position one" do
      keep = tile("all done", position: 5)
      drop = tile("all done", position: 40)

      expect { described_class.collapse_duplicates!(board) }
        .to change { board.board_images.count }.by(-1)

      expect(board.board_images.exists?(keep.id)).to be(true)
      expect(board.board_images.exists?(drop.id)).to be(false)
    end

    it "keeps the lowest-position copy regardless of insertion order" do
      late = tile("all done", position: 57)
      early = tile("all done", position: 39)

      described_class.collapse_duplicates!(board)

      expect(board.board_images.exists?(early.id)).to be(true)
      expect(board.board_images.exists?(late.id)).to be(false)
    end

    it "does not merge a word tile with its same-named category folder" do
      folder_target = create(:board, user: user)
      tile("play", position: 3)
      tile("Play", position: 50, predictive_board_id: folder_target.id)

      expect { described_class.collapse_duplicates!(board) }
        .not_to change { board.board_images.count }
    end

    it "collapses three copies down to one" do
      tile("all done", position: 1)
      tile("all done", position: 2)
      tile("all done", position: 3)

      expect { described_class.collapse_duplicates!(board) }
        .to change { board.board_images.count }.by(-2)
    end

    it "keeps the IN-GRID copy even when the off-grid duplicate has a lower position" do
      board.update_column(:large_screen_columns, 12)
      folder_target = create(:board, user: user)
      # The off-grid copy (x=13 on a 12-col board) was inserted first (low
      # position) — the exact Core 84 builder bug. The authored in-grid copy
      # (bottom row) came later. We must keep the in-grid one.
      off_grid = tile("More", position: 5, predictive_board_id: folder_target.id)
      off_grid.update_column(:layout, { "lg" => { "i" => off_grid.id.to_s, "x" => 13, "y" => 1, "w" => 1, "h" => 1 } })
      in_grid = tile("More", position: 40, predictive_board_id: folder_target.id)
      in_grid.update_column(:layout, { "lg" => { "i" => in_grid.id.to_s, "x" => 7, "y" => 6, "w" => 1, "h" => 1 } })

      expect { described_class.collapse_duplicates!(board) }
        .to change { board.board_images.count }.by(-1)

      expect(board.board_images.exists?(in_grid.id)).to be(true)
      expect(board.board_images.exists?(off_grid.id)).to be(false)
    end

    it "is a no-op on a clean board and returns 0" do
      tile("want", position: 1)
      tile("more", position: 2)

      expect(described_class.collapse_duplicates!(board)).to eq(0)
      expect(board.board_images.count).to eq(2)
    end

    it "dry_run reports the removable count without destroying" do
      tile("all done", position: 1)
      tile("all done", position: 2)

      expect(described_class.collapse_duplicates!(board, dry_run: true)).to eq(1)
      expect(board.board_images.count).to eq(2)
    end
  end
end
