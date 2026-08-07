require "rails_helper"

RSpec.describe Boards::AdminBuilder::PlanValidator do
  def tiles(*labels)
    labels.map { |label| { label: label, part_of_speech: "noun" } }
  end

  def pages(root_tiles:, columns: 2, rows: 2, children: [])
    Boards::AdminBuilder::Plan.pages(
      root: { name: "Playground", columns: columns, rows: rows, tiles: root_tiles },
      children: children,
    )
  end

  def validate(pages:, allow_partial_row: false, allow_mixed_grids: false)
    described_class.new(
      pages: pages, allow_partial_row: allow_partial_row, allow_mixed_grids: allow_mixed_grids,
    ).call
  end

  describe "a single board" do
    it "accepts a plan that exactly fills the grid" do
      expect(validate(pages: pages(root_tiles: tiles("i", "want", "more", "help")))).to eq([])
    end

    it "rejects a short plan and says how many to add" do
      problems = validate(pages: pages(root_tiles: tiles("i", "want", "more")))
      expect(problems.first).to include("3 words for a 2×2 grid (needs exactly 4)")
      expect(problems.first).to include("Add 1")
    end

    # A one-board build must read exactly as it did before pages existed.
    it "does not prefix messages with a page name" do
      problems = validate(pages: pages(root_tiles: tiles("i", "want", "more")))
      expect(problems.first).not_to include("Playground:")
    end

    it "allows a short plan when the partial-row escape hatch is ticked" do
      expect(validate(pages: pages(root_tiles: tiles("i", "want", "more")), allow_partial_row: true)).to eq([])
    end

    it "rejects an over-full plan even with the escape hatch ticked" do
      problems = validate(pages: pages(root_tiles: tiles("i", "want", "more", "help", "stop")), allow_partial_row: true)
      expect(problems.first).to include("won't fit")
      expect(problems.first).to include("Remove 1")
    end

    it "rejects an empty word list" do
      expect(validate(pages: pages(root_tiles: []))).to eq(["Add at least one word."])
    end

    it "rejects a grid with no columns or rows" do
      expect(validate(pages: pages(root_tiles: tiles("i"), columns: 0)))
        .to eq(["Set both a column count and a row count."])
    end

    it "rejects a blank label" do
      plan = tiles("i", "want", "more") + [{ label: "", part_of_speech: "noun" }]
      expect(validate(pages: pages(root_tiles: plan))).to include(a_string_including("Every tile needs a word"))
    end

    it "rejects duplicate labels" do
      problems = validate(pages: pages(root_tiles: tiles("i", "want", "want", "help")))
      expect(problems).to include(a_string_including("Duplicate words: want"))
    end

    # images.label is a lowercase matching key, so "Want" and "want" resolve to
    # the same symbol — two cells spent on one tile.
    it "treats a casing-only difference as a duplicate" do
      problems = validate(pages: pages(root_tiles: tiles("i", "Want", "want", "help")))
      expect(problems).to include(a_string_including("Duplicate words: want"))
    end

    it "rejects a part of speech outside the Fitzgerald key" do
      plan = tiles("i", "want", "more") + [{ label: "help", part_of_speech: "gerund" }]
      expect(validate(pages: pages(root_tiles: plan))).to include(a_string_including("Unknown part of speech: gerund"))
    end

    it "accepts every canonical part of speech" do
      ColorHelper::PARTS_OF_SPEECH.each do |pos|
        problems = validate(pages: pages(root_tiles: [{ label: "word", part_of_speech: pos }], columns: 1, rows: 1))
        expect(problems).to eq([]), "expected #{pos} to be accepted"
      end
    end

    it "defaults a missing part of speech rather than rejecting it" do
      expect(validate(pages: pages(root_tiles: [{ label: "word" }], columns: 1, rows: 1))).to eq([])
    end
  end

  describe "child pages" do
    def child(key: "food", name: "Food", tiles_list: nil, **overrides)
      { key: key, name: name, tiles: tiles_list || tiles("apple", "banana", "hungry", "more") }.merge(overrides)
    end

    let(:root_with_folder) do
      tiles("i", "want", "more") + [{ label: "Food", part_of_speech: "noun", links_to: "food" }]
    end

    it "accepts a root plus a page that fills the same grid" do
      expect(validate(pages: pages(root_tiles: root_with_folder, children: [child]))).to eq([])
    end

    it "names the page in its own problems" do
      problems = validate(pages: pages(root_tiles: root_with_folder, children: [child(tiles_list: tiles("apple"))]))
      expect(problems).to include(a_string_including("Food: 1 words for a 2×2 grid"))
    end

    it "rejects a tile pointing at a page that doesn't exist" do
      root = tiles("i", "want", "more") + [{ label: "Food", part_of_speech: "noun", links_to: "nope" }]
      problems = validate(pages: pages(root_tiles: root, children: [child]))
      expect(problems).to include(a_string_including("opens page “nope”, which doesn't exist"))
    end

    # A back-to-home tile is normal, not an error.
    it "accepts a page tile linking back to the main board" do
      back = tiles("apple", "banana", "hungry") +
             [{ label: "back", part_of_speech: "social", links_to: Boards::AdminBuilder::Plan::ROOT_KEY }]
      expect(validate(pages: pages(root_tiles: root_with_folder, children: [child(tiles_list: back)]))).to eq([])
    end

    it "accepts two pages linking to each other" do
      root = tiles("i", "want", "more") + [{ label: "Food", part_of_speech: "noun", links_to: "food" }]
      food = tiles("apple", "banana", "hungry") + [{ label: "Play", part_of_speech: "noun", links_to: "play" }]
      play = tiles("ball", "run", "swing") + [{ label: "Food", part_of_speech: "noun", links_to: "food" }]

      expect(validate(pages: pages(
        root_tiles: root,
        children: [child(tiles_list: food), child(key: "play", name: "Play", tiles_list: play)],
      ))).to eq([])
    end

    it "rejects a duplicate page key" do
      problems = validate(pages: pages(root_tiles: root_with_folder, children: [child, child]))
      expect(problems).to include(a_string_including("Duplicate page keys: food"))
    end

    it "rejects a blank page key" do
      problems = validate(pages: pages(root_tiles: root_with_folder, children: [child(key: "")]))
      expect(problems).to include(a_string_including("Page 1 needs a key"))
    end

    it "rejects a page claiming the root's key" do
      problems = validate(pages: pages(
        root_tiles: root_with_folder, children: [child(key: Boards::AdminBuilder::Plan::ROOT_KEY)],
      ))
      expect(problems).to include(a_string_including("that's the main board"))
    end

    it "rejects a key that isn't a usable token" do
      problems = validate(pages: pages(root_tiles: root_with_folder, children: [child(key: "my food!")]))
      expect(problems).to include(a_string_including("lowercase letters, numbers and underscores"))
    end

    it "rejects a page with no name" do
      problems = validate(pages: pages(root_tiles: root_with_folder, children: [child(name: "")]))
      expect(problems).to include(a_string_including("give the page a name"))
    end
  end

  describe "shared grid" do
    let(:root_with_folder) do
      tiles("i", "want", "more") + [{ label: "Food", part_of_speech: "noun", links_to: "food" }]
    end

    def sized_child(columns:, rows:, count:)
      {
        key: "food", name: "Food", columns: columns, rows: rows,
        tiles: Array.new(count) { |i| { label: "word#{i}", part_of_speech: "noun" } },
      }
    end

    # A communicator moving into a folder page shouldn't have the cell size
    # change under their finger.
    it "rejects a page whose authored grid differs from the main board's" do
      problems = validate(pages: pages(root_tiles: root_with_folder, children: [sized_child(columns: 3, rows: 3, count: 9)]))
      expect(problems).to include(a_string_including("grid 3×3 differs from the main board's 2×2"))
    end

    it "allows a different grid when the escape hatch is ticked" do
      problems = validate(
        pages: pages(root_tiles: root_with_folder, children: [sized_child(columns: 3, rows: 3, count: 9)]),
        allow_mixed_grids: true,
      )
      expect(problems).to eq([])
    end

    it "says nothing about a page that inherited the grid" do
      problems = validate(pages: pages(
        root_tiles: root_with_folder,
        children: [{ key: "food", name: "Food", tiles: tiles("apple", "banana", "hungry", "more") }],
      ))
      expect(problems).to eq([])
    end

    # Matching the root explicitly is the same board as inheriting it.
    it "accepts a page that restates the main board's grid" do
      problems = validate(pages: pages(root_tiles: root_with_folder, children: [sized_child(columns: 2, rows: 2, count: 4)]))
      expect(problems).to eq([])
    end
  end
end
