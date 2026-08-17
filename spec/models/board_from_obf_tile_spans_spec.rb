require "rails_helper"

# OBF has no colspan, so a file states tile size either by repeating a button
# id across the cells it covers or with explicit ext_speakanyway_w/_h. The
# importer used to hardcode {"w" => 1, "h" => 1}, which flattened every
# imported board to a uniform grid — a 13-column board whose word tiles should
# span 3-4 columns came in as 46 one-cell tiles with holes between them.
RSpec.describe "Board.from_obf tile spans", type: :model do
  let(:user) { create(:user) }

  def obf(buttons:, order:, columns: 4)
    {
      "id" => "spans",
      "name" => "Spans",
      "buttons" => buttons,
      "grid" => { "rows" => order.length, "columns" => columns, "order" => order },
      "images" => [],
    }
  end

  def layout_for(board, label)
    board.board_images.joins(:image).find_by(images: { label: label }).layout["lg"]
  end

  def button(id, label)
    { "id" => id, "label" => label }
  end

  describe "spans derived from repeated ids in the grid" do
    it "reads a horizontal run as one wide tile" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes"), button("b2", "no")],
            order: [%w[b1 b1 b1 b2]]),
        user
      )

      expect(board.board_images.count).to eq(2)
      expect(layout_for(board, "yes")).to include("x" => 0, "y" => 0, "w" => 3, "h" => 1)
      expect(layout_for(board, "no")).to include("x" => 3, "y" => 0, "w" => 1, "h" => 1)
    end

    it "reads a vertical run as one tall tile" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "help"), button("b2", "stop")],
            order: [%w[b1 b2], %w[b1 b2]], columns: 2),
        user
      )

      expect(layout_for(board, "help")).to include("x" => 0, "y" => 0, "w" => 1, "h" => 2)
    end

    it "reads a filled rectangle as one block tile" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "help")],
            order: [%w[b1 b1], %w[b1 b1]], columns: 2),
        user
      )

      expect(layout_for(board, "help")).to include("x" => 0, "y" => 0, "w" => 2, "h" => 2)
    end

    it "still places a single-cell button at 1x1" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes")], order: [["b1"]], columns: 1),
        user
      )

      expect(layout_for(board, "yes")).to include("x" => 0, "y" => 0, "w" => 1, "h" => 1)
    end

    it "honors nulls between tiles rather than filling them" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes"), button("b2", "no")],
            order: [["b1", nil, "b2", nil]]),
        user
      )

      expect(layout_for(board, "yes")).to include("x" => 0, "w" => 1)
      expect(layout_for(board, "no")).to include("x" => 2, "w" => 1)
    end
  end

  describe "malformed spans" do
    # The dangerous case: one id in two far-apart cells. Taking the bounding
    # box would stretch the tile across everything between them.
    it "falls back to 1x1 at the first cell when the cells aren't contiguous" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes"), button("b2", "no")],
            order: [["b1", "b2", nil, "b1"]]),
        user
      )

      expect(layout_for(board, "yes")).to include("x" => 0, "y" => 0, "w" => 1, "h" => 1)
    end

    it "falls back to 1x1 when the cells form an L rather than a rectangle" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes")],
            order: [%w[b1 b1], ["b1", nil]], columns: 2),
        user
      )

      expect(layout_for(board, "yes")).to include("w" => 1, "h" => 1)
    end
  end

  describe "explicit ext_speakanyway_w / _h" do
    it "overrides the span derived from the grid" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes").merge("ext_speakanyway_w" => 3)],
            order: [["b1", nil, nil, nil]]),
        user
      )

      expect(layout_for(board, "yes")).to include("x" => 0, "w" => 3, "h" => 1)
    end

    it "sets height independently" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes").merge("ext_speakanyway_h" => 2)],
            order: [["b1", nil, nil, nil]]),
        user
      )

      expect(layout_for(board, "yes")).to include("w" => 1, "h" => 2)
    end

    it "clamps a width that would run past the right edge of the board" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes").merge("ext_speakanyway_w" => 99)],
            order: [[nil, nil, "b1", nil]]),
        user
      )

      # x = 2 on a 4-column board leaves room for 2.
      expect(layout_for(board, "yes")).to include("x" => 2, "w" => 2)
    end

    it "ignores zero, negative, and non-numeric values" do
      board, = Board.from_obf(
        obf(buttons: [
              button("b1", "yes").merge("ext_speakanyway_w" => 0),
              button("b2", "no").merge("ext_speakanyway_w" => -4),
              button("b3", "help").merge("ext_speakanyway_w" => "wide"),
            ],
            order: [["b1", "b2", "b3", nil]]),
        user
      )

      %w[yes no help].each do |label|
        expect(layout_for(board, label)).to include("w" => 1, "h" => 1)
      end
    end
  end

  describe "backward compatibility" do
    it "writes the span to every screen size, as before" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes")], order: [%w[b1 b1 b1 b1]]),
        user
      )

      tile = board.board_images.first
      expect(tile.layout["lg"]).to include("w" => 4)
      expect(tile.layout["md"]).to include("w" => 4)
      expect(tile.layout["sm"]).to include("w" => 4)
    end

    it "leaves a file with no spans and no ext_ fields laid out exactly as before" do
      board, = Board.from_obf(
        obf(buttons: [button("b1", "yes"), button("b2", "no"), button("b3", "help")],
            order: [%w[b1 b2 b3]], columns: 3),
        user
      )

      expect(board.board_images.map { |bi| bi.layout["lg"].slice("w", "h") })
        .to all(eq("w" => 1, "h" => 1))
    end
  end
end
