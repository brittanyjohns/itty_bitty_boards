require "rails_helper"

RSpec.describe Boards::AdminBuilder::FolderTiles do
  def tile(label, links_to: nil, part_of_speech: "noun")
    { label: label, part_of_speech: part_of_speech, links_to: links_to }.compact
  end

  def page(key, name: nil, tiles: [])
    { key: key, name: name, tiles: tiles }
  end

  def link(root_tiles:, children:, tile_count: 0)
    described_class.link(root_tiles: root_tiles, children: children, tile_count: tile_count)
  end

  describe ".link" do
    it "leaves a set alone when every page already has a door" do
      result = link(
        root_tiles: [tile("i"), tile("Food", links_to: "food")],
        children: [page("food", name: "Food", tiles: [tile("apple")])],
      )

      expect(result).not_to be_changed
      expect(result.tiles.map { |t| t[:links_to] }).to eq([nil, "food"])
    end

    it "appends a folder tile for a page nothing opens" do
      result = link(
        root_tiles: [tile("i"), tile("want")],
        children: [page("in_the_classroom", name: "In the classroom")],
      )

      expect(result).to be_changed
      expect(result.added).to eq([{ key: "in_the_classroom", label: "In the classroom" }])
      expect(result.tiles.last).to eq(
        label: "In the classroom",
        part_of_speech: "noun",
        # Pinned so Image#set_label's lowercase default can't fold a category
        # tile's authored capital.
        display_label: "In the classroom",
        links_to: "in_the_classroom",
      )
    end

    it "falls back to the key read as words when the page has no name" do
      result = link(root_tiles: [tile("i")], children: [page("snack_time")])

      expect(result.tiles.last[:label]).to eq("snack time")
    end

    it "adds one door per unlinked page" do
      result = link(
        root_tiles: [tile("i")],
        children: [page("food", name: "Food"), page("play", name: "Play")],
      )

      expect(result.tiles.map { |t| t[:links_to] }).to eq([nil, "food", "play"])
    end

    it "counts a link from a sibling page as a door" do
      result = link(
        root_tiles: [tile("i")],
        children: [
          page("food", name: "Food", tiles: [tile("Play", links_to: "play")]),
          page("play", name: "Play"),
        ],
      )

      expect(result.added.map { |a| a[:key] }).to eq(["food"])
    end

    it "promotes a plain tile that already says the page's word" do
      result = link(
        root_tiles: [tile("i"), tile("Food", part_of_speech: "default")],
        children: [page("food", name: "Food")],
      )

      expect(result.tiles.size).to eq(2)
      expect(result.tiles.last).to include(links_to: "food", part_of_speech: "noun", display_label: "Food")
    end

    it "matches a plain tile against the key read as words" do
      result = link(root_tiles: [tile("snack time")], children: [page("snack_time")])

      expect(result.tiles.size).to eq(1)
      expect(result.tiles.first[:links_to]).to eq("snack_time")
    end

    it "retargets a tile whose link names a page that doesn't exist" do
      result = link(
        root_tiles: [tile("i"), tile("Food", links_to: "fod")],
        children: [page("food", name: "Food")],
      )

      expect(result.tiles.size).to eq(2)
      expect(result.tiles.last[:links_to]).to eq("food")
    end

    it "never takes over a tile that already opens a real page" do
      result = link(
        root_tiles: [tile("Food", links_to: "play")],
        children: [page("food", name: "Food"), page("play", name: "Play")],
      )

      expect(result.tiles.map { |t| t[:links_to] }).to eq(["play", "food"])
    end

    it "normalizes the key it writes" do
      result = link(root_tiles: [tile("i")], children: [page("  FOOD  ", name: "Food")])

      expect(result.tiles.last[:links_to]).to eq("food")
      expect(result.added.first[:key]).to eq("food")
    end
  end

  describe "keys it refuses to link" do
    it "skips a page with no key — PlanValidator says so in its own words" do
      result = link(root_tiles: [tile("i")], children: [page("", name: "Food")])

      expect(result).not_to be_changed
    end

    it "skips a key that isn't lowercase letters, numbers and underscores" do
      result = link(root_tiles: [tile("i")], children: [page("food page!", name: "Food")])

      expect(result).not_to be_changed
    end

    it "skips a page claiming the root's own key" do
      result = link(root_tiles: [tile("i")], children: [page(Boards::AdminBuilder::Plan::ROOT_KEY)])

      expect(result).not_to be_changed
    end
  end

  describe "making room on a full main board" do
    it "drops trailing plain words when the board is already at its tile count" do
      result = link(
        root_tiles: [tile("i"), tile("want"), tile("more"), tile("help")],
        children: [page("food", name: "Food")],
        tile_count: 4,
      )

      expect(result.tiles.map { |t| t[:label] }).to eq(["i", "want", "more", "Food"])
      expect(result.displaced).to eq(["help"])
    end

    it "drops as many as it needs, from the end, in reading order" do
      result = link(
        root_tiles: [tile("i"), tile("want"), tile("more"), tile("help")],
        children: [page("food", name: "Food"), page("play", name: "Play")],
        tile_count: 4,
      )

      expect(result.tiles.map { |t| t[:label] }).to eq(["i", "want", "Food", "Play"])
      expect(result.displaced).to eq(["more", "help"])
    end

    it "never drops another page's door to make room" do
      result = link(
        root_tiles: [tile("i"), tile("want"), tile("more"), tile("Play", links_to: "play")],
        children: [page("play", name: "Play"), page("food", name: "Food")],
        tile_count: 4,
      )

      expect(result.tiles.map { |t| t[:label] }).to eq(["i", "want", "Play", "Food"])
      expect(result.displaced).to eq(["more"])
    end

    it "displaces nothing when promoting an existing tile" do
      result = link(
        root_tiles: [tile("i"), tile("want"), tile("more"), tile("Food")],
        children: [page("food", name: "Food")],
        tile_count: 4,
      )

      expect(result.tiles.size).to eq(4)
      expect(result.displaced).to be_empty
    end

    it "displaces nothing when there is room" do
      result = link(root_tiles: [tile("i")], children: [page("food", name: "Food")], tile_count: 4)

      expect(result.tiles.size).to eq(2)
      expect(result.displaced).to be_empty
    end

    it "displaces nothing when no tile count is set" do
      result = link(root_tiles: [tile("i")], children: [page("food", name: "Food")])

      expect(result.displaced).to be_empty
    end
  end

  describe ".reserved_count" do
    it "counts the pages a from-scratch root draft will have to leave room for" do
      children = [page("food"), page("play"), page(""), page("Nope!")]

      expect(described_class.reserved_count(children: children)).to eq(2)
    end
  end
end
