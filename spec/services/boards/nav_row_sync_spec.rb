require "rails_helper"

RSpec.describe Boards::NavRowSync do
  let(:user) { create(:user) }
  let!(:root) { create(:board, user: user, name: "Core 60", large_screen_columns: 6) }
  let!(:food) { create(:board, user: user, name: "Food", large_screen_columns: 6) }
  let!(:drinks) { create(:board, user: user, name: "Drinks", large_screen_columns: 6) }

  def tile(board, label, x:, y:, position:, target: nil, data: {})
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target, data: data)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  # Root: a content row, then a nav row of `this | Food | Drinks | that`.
  before do
    %w[I want go stop].each_with_index { |l, x| tile(root, l, x: x, y: 0, position: x + 1) }
    tile(root, "this", x: 0, y: 1, position: 10)
    tile(root, "Food", x: 1, y: 1, position: 11, target: food.id)
    tile(root, "Drinks", x: 2, y: 1, position: 12, target: drinks.id)
    tile(root, "that", x: 3, y: 1, position: 13)
  end

  def nav_cells(board)
    board.board_images.reload.select { |bi| bi.data&.dig("nav_tile") }.map do |bi|
      { label: bi.label, x: bi.layout["lg"]["x"], y: bi.layout["lg"]["y"],
        target: bi.predictive_board_id, muted: bi.data["mute_name"] }
    end.sort_by { |c| [c[:y], c[:x]] }
  end

  it "projects the root's nav row onto every child at the same cells" do
    described_class.call(root)

    expect(nav_cells(food).map { |c| [c[:label], c[:x], c[:y]] }).to eq(
      [["this", 0, 1], ["Food", 1, 1], ["Drinks", 2, 1], ["that", 3, 1]]
    )
  end

  it "points the self-tile at the root and leaves it unmuted" do
    described_class.call(root)

    self_tile = nav_cells(food).find { |c| c[:label] == "Food" }
    other     = nav_cells(food).find { |c| c[:label] == "Drinks" }

    expect(self_tile[:target]).to eq(root.id)
    expect(self_tile[:muted]).to be_falsey
    expect(other[:target]).to eq(drinks.id)
    expect(other[:muted]).to be(true)
  end

  it "is idempotent" do
    described_class.call(root)
    first = nav_cells(food)

    expect { described_class.call(root) }.not_to change { food.board_images.reload.count }
    expect(nav_cells(food)).to eq(first)
  end

  it "deletes the legacy back-to-home tile the nav row replaces" do
    tile(food, "Home", x: 0, y: 1, position: 1, target: root.id)

    result = described_class.call(root)

    expect(food.board_images.reload.map(&:label)).not_to include("Home")
    expect(result.folders_deleted).to eq(1)
  end

  it "deletes a shifted legacy category tile even when it misses a nav cell" do
    # Pre-sync pages packed the nav row left to fill the gap left by their own
    # tile, so `Drinks` sits a cell over from where the region wants it.
    tile(food, "Drinks", x: 0, y: 0, position: 1, target: drinks.id)

    described_class.call(root)

    drinks_tiles = food.board_images.reload.select { |bi| bi.label == "Drinks" }
    expect(drinks_tiles.size).to eq(1)
    expect(drinks_tiles.first.data["nav_tile"]).to be(true)
  end

  it "keeps a page's own content folder tiles" do
    # The Phrases page links the six gestalt function boards; those are its
    # content, not a stale nav row.
    greetings = create(:board, user: user, name: "Greetings", large_screen_columns: 6)
    phrases   = create(:board, user: user, name: "Phrases", large_screen_columns: 6)
    tile(root, "Phrases", x: 4, y: 1, position: 14, target: phrases.id)
    tile(phrases, "Greetings", x: 1, y: 1, position: 1, target: greetings.id)

    described_class.call(root)

    survivor = phrases.board_images.reload.find { |bi| bi.label == "Greetings" }
    expect(survivor).to be_present
    expect(survivor.predictive_board_id).to eq(greetings.id)
    expect(survivor.layout["lg"]["y"]).to be < 1 # relocated out of the nav cell
  end

  it "relocates a user's word tile out of a nav cell instead of deleting it" do
    tile(food, "pizza", x: 1, y: 1, position: 1)

    result = described_class.call(root)

    pizza = food.board_images.reload.find { |bi| bi.label == "pizza" }
    expect(pizza).to be_present                       # never dropped
    expect(pizza.layout["lg"]["y"]).to be < 1         # moved into the content area
    expect(result.words_relocated).to eq(1)
  end

  it "reaches depth-2 boards" do
    greetings = create(:board, user: user, name: "Greetings", large_screen_columns: 6)
    phrases   = create(:board, user: user, name: "Phrases", large_screen_columns: 6)
    tile(root, "Phrases", x: 4, y: 1, position: 14, target: phrases.id)
    tile(phrases, "Greetings", x: 0, y: 0, position: 1, target: greetings.id)

    described_class.call(root)

    expect(nav_cells(greetings).map { |c| c[:label] }).to include("Food", "Drinks", "Phrases")
  end

  it "writes nothing on a dry run but still reports the work" do
    result = described_class.call(root, dry_run: true)

    expect(food.board_images.reload).to be_empty
    expect(result.boards_synced).to eq(2)         # Food + Drinks
    expect(result.tiles_written).to eq(8)         # 4 nav cells x 2 pages
  end

  # Boards::FolderPlacer tucks build-added pages into the "More" drawer, so they
  # have no cell of their own in the nav region. They still need a one-tap way
  # home — every page in a built set has one.
  describe "a page with no nav cell of its own" do
    let!(:drawer) { create(:board, user: user, name: "More", large_screen_columns: 6) }
    let!(:animals) { create(:board, user: user, name: "Animals", large_screen_columns: 6) }

    before do
      # Swap the root's "Drinks" nav tile for the "More" drawer, and hang
      # Animals off the drawer rather than the home board.
      root.board_images.find_by(label: "Drinks").update!(label: "More", display_label: "More",
                                                        predictive_board_id: drawer.id)
      tile(drawer, "why", x: 0, y: 0, position: 1)
      tile(drawer, "Animals", x: 1, y: 0, position: 2, target: animals.id)
      tile(animals, "dog", x: 0, y: 0, position: 1)
    end

    it "gives it a tile named for the page that opens the root" do
      described_class.call(root)

      home = animals.board_images.reload.find { |bi| bi.predictive_board_id == root.id }
      expect(home).to be_present, "Animals has no way home"
      expect(home.display_label).to eq("Animals")
      expect(home.data.to_h["mute_name"]).not_to be(true)
    end

    it "gives every page in the set a way home" do
      described_class.call(root)

      [food, drawer, animals].each do |page|
        expect(page.board_images.reload.map(&:predictive_board_id)).to include(root.id),
          "#{page.name} has no way home"
      end
    end

    it "does not add a second anchor to a page that already has its self tile" do
      described_class.call(root)

      home_tiles = food.board_images.reload.select { |bi| bi.predictive_board_id == root.id }
      expect(home_tiles.size).to eq(1)
      expect(home_tiles.first.label).to eq("Food")
    end

    # The way home goes where the way in was. "Animals" sits at (1, 0) on the
    # drawer, so that is where the anchor lands — not the first free cell.
    it "puts the anchor in the same cell as the tile that opens the page" do
      described_class.call(root)

      home = animals.board_images.reload.find { |bi| bi.predictive_board_id == root.id }
      expect([home.layout["lg"]["x"], home.layout["lg"]["y"]]).to eq([1, 0])
    end

    it "swaps with whatever occupied that cell rather than dropping it" do
      tile(animals, "cat", x: 1, y: 0, position: 2)

      described_class.call(root)

      home = animals.board_images.reload.find { |bi| bi.predictive_board_id == root.id }
      cat = animals.board_images.reload.find { |bi| bi.label == "cat" }
      expect([home.layout["lg"]["x"], home.layout["lg"]["y"]]).to eq([1, 0])
      expect(cat).to be_present
      expect([cat.layout["lg"]["x"], cat.layout["lg"]["y"]]).not_to eq([1, 0])
      # Still in the content area, not pushed into the nav region.
      expect(cat.layout["lg"]["y"]).to eq(0)
    end

    # A drawer's content area can be taller than the page it opens, so a
    # mirrored cell that would land inside the nav region is refused outright
    # rather than clamped into it, where it would fight the nav tiles.
    it "falls back to the first free cell when the mirrored cell is in the nav region" do
      animals.board_images.destroy_all
      drawer.board_images.find_by(label: "Animals").update_column(
        :layout, { "lg" => { "x" => 3, "y" => 4, "w" => 1, "h" => 1 } }
      )

      described_class.call(root)

      home = animals.board_images.reload.find { |bi| bi.predictive_board_id == root.id }
      expect([home.layout["lg"]["x"], home.layout["lg"]["y"]]).to eq([0, 0])
    end
  end
end
