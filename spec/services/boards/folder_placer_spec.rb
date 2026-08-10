require "rails_helper"

RSpec.describe Boards::FolderPlacer do
  let(:user) { create(:user) }
  let(:root) { create(:board, user: user, name: "Core 60", large_screen_columns: 4) }
  let(:drawer) { create(:board, user: user, name: "More", large_screen_columns: 4) }

  # A tile at an exact lg cell. update_columns bypasses the layout callbacks so
  # x/y stay precisely where the test puts them.
  def tile(board, label, x:, y:, position:, target: nil)
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, display_label: label, predictive_board_id: target)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  # A miniature Core 60: a full content row, then a nav row carrying the "More"
  # drawer. 8 tiles in a 4x2 grid — zero open cells, like the real authored set.
  def build_full_root!(with_drawer: true)
    pos = 0
    %w[I want go stop].each_with_index { |label, x| tile(root, label, x: x, y: 0, position: pos += 1) }
    tile(root, "this", x: 0, y: 1, position: pos += 1)
    tile(root, "People", x: 1, y: 1, position: pos += 1, target: create(:board, user: user, name: "People").id)
    if with_drawer
      tile(root, "More", x: 2, y: 1, position: pos += 1, target: drawer.id)
    else
      tile(root, "here", x: 2, y: 1, position: pos += 1)
    end
    tile(root, "that", x: 3, y: 1, position: pos += 1)
  end

  # The drawer as authored: a partly-filled content row (gaps at x=2,3), an
  # empty row, then its own nav row at the bottom.
  def build_drawer!
    pos = 0
    %w[why how].each_with_index { |label, x| tile(drawer, label, x: x, y: 0, position: pos += 1) }
    tile(drawer, "this", x: 0, y: 2, position: pos += 1)
    tile(drawer, "People", x: 1, y: 2, position: pos += 1, target: create(:board, user: user, name: "People2").id)
    tile(drawer, "More", x: 2, y: 2, position: pos += 1, target: root.id)
    tile(drawer, "that", x: 3, y: 2, position: pos += 1)
  end

  def page!(name)
    create(:board, user: user, name: name)
  end

  def place!(name, board_id)
    described_class.place!(root: root, owner: user, name: name, board_id: board_id)
  end

  def lg_cell(tile)
    tile.reload.layout["lg"].slice("x", "y")
  end

  describe "with room on the home grid" do
    it "places the folder tile on the home board" do
      build_full_root!
      build_drawer!
      root.board_images.order(:position).last.destroy # free one cell

      bathroom = page!("Bathroom")
      result = place!("Bathroom", bathroom.id)

      expect(result.destination).to eq(:root)
      expect(result.board.id).to eq(root.id)
      expect(result.tile.predictive_board_id).to eq(bathroom.id)
      expect(drawer.board_images.reload.map(&:label)).not_to include("Bathroom")
    end
  end

  describe "with a full home grid and a More drawer" do
    before do
      build_full_root!
      build_drawer!
    end

    it "tucks the page into the drawer and leaves the authored grid untouched" do
      bathroom = page!("Bathroom")

      result = place!("Bathroom", bathroom.id)

      expect(result.destination).to eq(:drawer)
      expect(result.board.id).to eq(drawer.id)
      expect(root.board_images.reload.count).to eq(8)
      expect(root.reload.large_screen_rows).to eq(2)
      expect(drawer.board_images.reload.map(&:label)).to include("Bathroom")
    end

    it "pins the authored folder name and the board it opens" do
      bathroom = page!("Bathroom")

      tile = place!("Bathroom", bathroom.id).tile

      expect(tile.label).to eq("Bathroom")
      expect(tile.display_label).to eq("Bathroom")
      expect(tile.predictive_board_id).to eq(bathroom.id)
    end

    it "starts a band on the first empty row rather than filling gaps in a word row" do
      tile = place!("Bathroom", page!("Bathroom").id).tile

      # y=0 has open cells at x=2,3, but it is authored content — the band goes
      # on the empty row instead.
      expect(lg_cell(tile)).to eq({ "x" => 0, "y" => 1 })
    end

    it "packs successive pages into the same band instead of one row each" do
      first  = place!("Bathroom", page!("Bathroom").id).tile
      second = place!("Animals", page!("Animals").id).tile
      third  = place!("Music", page!("Music").id).tile

      expect(lg_cell(first)).to eq({ "x" => 0, "y" => 1 })
      expect(lg_cell(second)).to eq({ "x" => 1, "y" => 1 })
      expect(lg_cell(third)).to eq({ "x" => 2, "y" => 1 })
    end

    it "mirrors the placement into the drawer's own layout column" do
      tile = place!("Bathroom", page!("Bathroom").id).tile

      expect(drawer.reload.layout["lg"][tile.id.to_s]).to include("x" => 0, "y" => 1)
    end

    # Boards::NavRowSync destroys any folder tile on a child page whose label
    # matches a nav category, so a colliding page tucked into the drawer would
    # be silently orphaned.
    it "keeps a page whose name collides with a nav label on the home board" do
      people = page!("People")

      result = place!("People", people.id)

      expect(result.destination).to eq(:grown)
      expect(result.board.id).to eq(root.id)
    end

    it "falls back to growing the home grid once the drawer is full" do
      # The drawer holds 6 more tiles above its nav row: the empty row (4) plus
      # the two gaps in its word row.
      results = 7.times.map { |i| place!("Page#{i}", page!("Page#{i}").id) }

      expect(results.first(6).map(&:destination)).to all(eq(:drawer))
      expect(results.last.destination).to eq(:grown)
      expect(results.last.board.id).to eq(root.id)
    end
  end

  describe "with no drawer (legacy starter trees)" do
    it "grows the home grid as before" do
      build_full_root!(with_drawer: false)

      result = place!("Bathroom", page!("Bathroom").id)

      expect(result.destination).to eq(:grown)
      expect(result.board.id).to eq(root.id)
      expect(root.board_images.reload.count).to eq(9)
    end
  end

  describe ".drawer_for" do
    it "finds the board the root's More tile opens" do
      build_full_root!

      expect(described_class.drawer_for(root)&.id).to eq(drawer.id)
    end

    it "is nil when the root has no More folder tile" do
      build_full_root!(with_drawer: false)

      expect(described_class.drawer_for(root)).to be_nil
    end

    it "ignores a More tile pointing at another user's board" do
      build_full_root!
      drawer.update!(user: create(:user))

      expect(described_class.drawer_for(root)).to be_nil
    end
  end
end
