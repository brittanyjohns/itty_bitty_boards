require "rails_helper"

RSpec.describe Boards::NavRegion do
  let(:user) { create(:user) }
  let(:root) { create(:board, user: user, large_screen_columns: 10) }

  # A tile at an exact lg cell. update_column bypasses the layout callbacks so
  # x/y stay precisely where the test puts them.
  def tile(label, x:, y:, position:, target: nil)
    bi = create(:board_image, board: root, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  # A miniature Core 60: one content row, then a nav row of 4 folders flanked
  # by the `this`/`that` word tiles.
  def build_core_60!
    pos = 0
    %w[I want go stop like have].each_with_index do |label, x|
      tile(label, x: x, y: 0, position: pos += 1)
    end
    tile("this", x: 0, y: 1, position: pos += 1)
    %w[People Feelings Food Drinks].each_with_index do |label, i|
      page = create(:board, user: user, name: label)
      tile(label, x: i + 1, y: 1, position: pos += 1, target: page.id)
    end
    tile("that", x: 5, y: 1, position: pos += 1)
  end

  describe ".for_root" do
    it "treats the bottom row as the nav region" do
      build_core_60!

      result = described_class.for_root(root)

      expect(result.rows).to eq([1])
      expect(result.row_count).to eq(1)
      expect(result.cells.map(&:label)).to contain_exactly(
        "this", "People", "Feelings", "Food", "Drinks", "that"
      )
    end

    it "includes an all-folder row above the nav row as the added row" do
      build_core_60!
      %w[Animals Phrases].each_with_index do |label, i|
        page = create(:board, user: user, name: label)
        tile(label, x: i, y: 2, position: 100 + i, target: page.id)
      end

      result = described_class.for_root(root)

      # y=2 is all folders, so it aligns to sit ABOVE the rotated nav row.
      expect(result.rows).to eq([1, 2])
      expect(result.cells.map(&:label)).to include("Animals", "Phrases", "People", "that")
    end

    it "does not swallow a content row that merely contains a folder tile" do
      build_core_60!
      # Core 84's `More`: a lone folder tile parked in a row of words.
      more_page = create(:board, user: user, name: "More")
      tile("More", x: 6, y: 0, position: 200, target: more_page.id)

      result = described_class.for_root(root)

      expect(result.rows).to eq([1])                       # y=0 is NOT a nav row
      expect(result.cells.map(&:label)).to include("More") # but More is pinned
      expect(result.cells.map(&:label)).not_to include("I", "want")
    end

    it "returns an empty result for a board with no folder tiles" do
      tile("apple", x: 0, y: 0, position: 1)

      expect(described_class.for_root(root)).to be_empty
    end
  end

  describe ".align" do
    it "rotates the authored nav row to the bottom and lifts the rows below it" do
      build_core_60!
      page = create(:board, user: user, name: "Animals")
      tile("Animals", x: 0, y: 2, position: 100, target: page.id)

      aligned = described_class.align(described_class.placed_tiles(root))
      by_label = aligned.index_by(&:label)

      expect(by_label["Animals"].y).to eq(1) # lifted
      expect(by_label["People"].y).to eq(2)  # nav row now last
      expect(by_label["I"].y).to eq(0)       # content untouched
    end

    it "is a no-op when the nav row is already last" do
      build_core_60!
      tiles = described_class.placed_tiles(root)

      expect(described_class.align(tiles).map(&:y)).to eq(tiles.map(&:y))
    end
  end

  describe ".authored_nav_y" do
    it "picks the row with the most folder tiles" do
      build_core_60!
      page = create(:board, user: user, name: "Animals")
      tile("Animals", x: 0, y: 2, position: 100, target: page.id)

      expect(described_class.authored_nav_y(described_class.placed_tiles(root))).to eq(1)
    end

    it "breaks ties toward the lowest row index" do
      a = create(:board, user: user, name: "A")
      b = create(:board, user: user, name: "B")
      tile("A", x: 0, y: 1, position: 1, target: a.id)
      tile("B", x: 0, y: 4, position: 2, target: b.id)

      expect(described_class.authored_nav_y(described_class.placed_tiles(root))).to eq(1)
    end
  end

  describe ".for_board" do
    it "reserves nothing on an ordinary board that merely holds folder tiles" do
      build_core_60!

      expect(described_class.for_board(root)).to be_empty
    end

    it "reads a Board Builder root geometrically" do
      build_core_60!
      root.update_columns(settings: (root.settings || {}).merge("builder_root" => true))

      expect(described_class.for_board(root).cells.map(&:label)).to contain_exactly(
        "this", "People", "Feelings", "Food", "Drinks", "that"
      )
    end

    it "reads an imported set's pinned root geometrically" do
      build_core_60!
      root.update_columns(settings: (root.settings || {}).merge(Board::MAIN_BOARD_PIN => true))

      expect(described_class.for_board(root).cells.map(&:label)).to include("People", "that")
    end

    # A synced page carries the flags NavRowSync owns, so the region is exactly
    # those tiles — no geometry, and no need for the page to be pinned.
    it "reads a synced page from its nav flags" do
      build_core_60!
      root.board_images.each do |bi|
        next unless %w[People Feelings Food Drinks this that].include?(bi.label)

        flag = bi.predictive_board_id ? "nav_tile" : "nav_word"
        bi.update_column(:data, (bi.data || {}).merge(flag => true))
      end
      root.board_images.reset

      result = described_class.for_board(root)

      expect(result.rows).to eq([1])
      expect(result.cells.map(&:label)).to contain_exactly(
        "this", "People", "Feelings", "Food", "Drinks", "that"
      )
    end

    # The flags say exactly which tiles the sync owns, so they win outright —
    # a page whose strip has been moved is still described by its flags.
    it "prefers the flags over the geometric read" do
      build_core_60!
      root.update_columns(settings: (root.settings || {}).merge("builder_root" => true))
      people = root.board_images.find { |bi| bi.label == "People" }
      people.update_column(:data, (people.data || {}).merge("nav_tile" => true))
      root.board_images.reset

      expect(described_class.for_board(root).cells.map(&:label)).to eq(["People"])
    end
  end
end
