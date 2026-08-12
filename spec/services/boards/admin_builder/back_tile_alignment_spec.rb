require "rails_helper"

RSpec.describe Boards::AdminBuilder::BackTileAlignment do
  def root_key = Boards::AdminBuilder::Plan::ROOT_KEY

  # Terse page/tile builders — these specs are about indexes, so the labels
  # exist only to be told apart.
  def tile(label, links_to: nil)
    { label: label, part_of_speech: "default", links_to: links_to }.compact
  end

  def page(key:, columns:, tiles:)
    { key: key, name: key, columns: columns, tile_count: tiles.size, tiles: tiles }
  end

  describe ".cell_indexes" do
    it "moves a page's back tile into the cell its folder tile occupies, swapping with the word there" do
      root = page(key: root_key, columns: 4, tiles: [
        tile("a"), tile("b"), tile("c"), tile("d"),
        tile("e"), tile("Food", links_to: "food"), tile("g"), tile("h")
      ])
      food = page(key: "food", columns: 4, tiles: [
        tile("apple"), tile("bread"), tile("cheese"), tile("dip"),
        tile("egg"), tile("fig"), tile("grape"), tile("back", links_to: root_key)
      ])

      cells = described_class.cell_indexes([root, food])

      # Folder tile is index 5 on a 4-wide root: x=1, y=1 -> cell 5 on the child.
      expect(cells["food"][7]).to eq(5)
      # The word that was in cell 5 takes the corner the back tile vacated.
      expect(cells["food"][5]).to eq(7)
      # Everything else keeps its authored slot.
      expect(cells["food"].values_at(0, 1, 2, 3, 4, 6)).to eq([0, 1, 2, 3, 4, 6])
      # The root itself is never rearranged.
      expect(cells[root_key]).to eq((0..7).to_a)
    end

    it "leaves the page alone when the back tile already sits in the mirrored cell" do
      root = page(key: root_key, columns: 2, tiles: [tile("a"), tile("Food", links_to: "food")])
      food = page(key: "food", columns: 2, tiles: [tile("apple"), tile("back", links_to: root_key)])

      expect(described_class.cell_indexes([root, food])["food"]).to eq([0, 1])
    end

    it "clamps x when the child grid is narrower than the parent's" do
      root = page(key: root_key, columns: 6, tiles: Array.new(5) { |i| tile("a#{i}") } + [tile("Food", links_to: "food")])
      food = page(key: "food", columns: 3, tiles: [
        tile("apple"), tile("bread"), tile("cheese"),
        tile("dip"), tile("egg"), tile("back", links_to: root_key)
      ])

      cells = described_class.cell_indexes([root, food])

      # Folder tile is x=5, y=0 on a 6-wide root; the child only has columns 0-2.
      expect(cells["food"][5]).to eq(2)
      expect(cells["food"][2]).to eq(5)
    end

    it "clamps y into a ragged last row when the child is shorter than the parent" do
      root = page(key: root_key, columns: 3, tiles: [
        tile("a"), tile("b"), tile("c"),
        tile("d"), tile("e"), tile("f"),
        tile("g"), tile("h"), tile("i"),
        tile("j"), tile("Food", links_to: "food")
      ])
      # Two full rows plus one cell: the mirrored y=3 doesn't exist here.
      food = page(key: "food", columns: 3, tiles: [
        tile("apple"), tile("bread"), tile("cheese"),
        tile("dip"), tile("egg"), tile("fig"),
        tile("back", links_to: root_key)
      ])

      cells = described_class.cell_indexes([root, food])

      # y clamps to the last row (2); x=1 there would be cell 7, which doesn't
      # exist either, so it clamps again to the last occupied cell.
      expect(cells["food"][6]).to eq(6)
      expect(cells["food"]).to eq((0..6).to_a)
    end

    it "mirrors a second-level page against its own parent, not the root" do
      root = page(key: root_key, columns: 3, tiles: [tile("a"), tile("b"), tile("Food", links_to: "food")])
      food = page(key: "food", columns: 3, tiles: [
        tile("apple"), tile("Snacks", links_to: "snacks"), tile("back", links_to: root_key)
      ])
      snacks = page(key: "snacks", columns: 3, tiles: [
        tile("chips"), tile("crackers"), tile("back", links_to: root_key)
      ])

      cells = described_class.cell_indexes([root, food, snacks])

      # "Snacks" is index 1 on the food page, so the snacks page's way home
      # goes to cell 1 — not cell 2, where the root's own folder tile sits.
      expect(cells["snacks"][2]).to eq(1)
      expect(cells["snacks"][1]).to eq(2)
      # Food still mirrors the root's folder tile at index 2.
      expect(cells["food"]).to eq([0, 1, 2])
    end

    it "prefers a back tile pointing at the actual parent over one pointing at the root" do
      root = page(key: root_key, columns: 3, tiles: [tile("a"), tile("b"), tile("Food", links_to: "food")])
      food = page(key: "food", columns: 3, tiles: [tile("apple"), tile("Snacks", links_to: "snacks"), tile("c")])
      snacks = page(key: "snacks", columns: 3, tiles: [
        tile("home", links_to: root_key), tile("chips"), tile("Food", links_to: "food")
      ])

      cells = described_class.cell_indexes([root, food, snacks])

      # The "Food" tile is the real way back; it moves to cell 1.
      expect(cells["snacks"][2]).to eq(1)
      expect(cells["snacks"][0]).to eq(0)
    end

    it "uses the shallowest parent when two pages link the same child" do
      root = page(key: root_key, columns: 3, tiles: [
        tile("a"), tile("Food", links_to: "food"), tile("Snacks", links_to: "snacks")
      ])
      food = page(key: "food", columns: 3, tiles: [
        tile("apple"), tile("Snacks", links_to: "snacks"), tile("back", links_to: root_key)
      ])
      snacks = page(key: "snacks", columns: 3, tiles: [
        tile("chips"), tile("crackers"), tile("back", links_to: root_key)
      ])

      cells = described_class.cell_indexes([root, food, snacks])

      # Reached from the root at index 2 (depth 1), not from food at index 1.
      expect(cells["snacks"]).to eq([0, 1, 2])
    end

    it "leaves a page with no back tile in authored order" do
      root = page(key: root_key, columns: 3, tiles: [tile("a"), tile("b"), tile("Food", links_to: "food")])
      food = page(key: "food", columns: 3, tiles: [tile("apple"), tile("bread"), tile("cheese")])

      expect(described_class.cell_indexes([root, food])["food"]).to eq([0, 1, 2])
    end

    it "leaves a page unreachable from the root alone" do
      root = page(key: root_key, columns: 2, tiles: [tile("a"), tile("b")])
      orphan = page(key: "orphan", columns: 2, tiles: [tile("x"), tile("back", links_to: root_key)])

      expect(described_class.cell_indexes([root, orphan])["orphan"]).to eq([0, 1])
    end

    it "handles a single-page plan, an empty page and a self-link without raising" do
      root = page(key: root_key, columns: 3, tiles: [tile("a"), tile("Home", links_to: root_key)])
      empty = page(key: "empty", columns: 3, tiles: [])

      cells = described_class.cell_indexes([root, empty])

      expect(cells[root_key]).to eq([0, 1])
      expect(cells["empty"]).to eq([])
      expect(described_class.cell_indexes([])).to eq({})
    end
  end
end
