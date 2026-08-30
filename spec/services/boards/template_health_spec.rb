require "rails_helper"

RSpec.describe Boards::TemplateHealth do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def template_board(category: "Animals", columns: 2, tiles: 2)
    board = create(:board, user: admin, name: category, predefined: true, published: true,
                   number_of_columns: columns, large_screen_columns: columns,
                   settings: { Boards::FringeTemplates::TEMPLATE_MARKER => category.downcase,
                               "disable_scroll" => true })
    tiles.times do |index|
      image = create(:image, label: "word#{index}")
      bi = create(:board_image, board: board, image: image, label: "word#{index}", position: index)
      bi.update_columns(layout: { "lg" => { "x" => index, "y" => 0, "w" => 1, "h" => 1 } })
    end
    board.reload
  end

  def health_for(board, **opts)
    described_class.new(board, kind: :fringe, category: board.settings[Boards::FringeTemplates::TEMPLATE_MARKER], **opts)
  end

  describe "reading the grid" do
    it "reports tile count, grid size and open cells without writing" do
      board = template_board(columns: 4, tiles: 2)
      health = health_for(board)

      expect { health.problems }.not_to change { board.reload.updated_at }
      expect(health.tile_count).to eq(2)
      expect(health.occupied_cells).to eq(2)
      expect(health.open_cells).to eq(2)
    end

    # The regression that motivates this class existing at all: Board#open_grid_cells
    # opens with update_board_layout, which saves the board and every tile.
    it "never writes to the board or its tiles" do
      board = template_board
      tile_stamps = board.board_images.pluck(:id, :updated_at)

      expect { described_class.new(board, kind: :fringe, category: "animals").problems }
        .not_to change { board.reload.updated_at }
      expect(board.board_images.pluck(:id, :updated_at)).to eq(tile_stamps)
    end
  end

  describe "stacked tiles" do
    it "flags two tiles parked on one cell" do
      board = template_board(columns: 4, tiles: 2)
      board.board_images.each { |bi| bi.update_columns(layout: { "lg" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } }) }

      health = health_for(board.reload)
      expect(health.displaced_tiles).to eq(1)
      expect(health).not_to be_healthy
      expect(health.problems.join(" ")).to include("stacked")
    end
  end

  describe "missing art" do
    it "does not count a tile whose picture is deliberately hidden" do
      board = template_board(tiles: 1)
      # A BLANK display_image_url is the "hide pictures" marker; nil falls
      # through to the shared Image's art. They must not read the same.
      board.board_images.first.update_columns(display_image_url: "")

      expect(health_for(board.reload).tiles_missing_art).to eq(0)
    end

    it "counts a tile with no picture and no art on its image" do
      board = template_board(tiles: 1)
      board.board_images.first.update_columns(display_image_url: nil)

      expect(health_for(board.reload).tiles_missing_art).to eq(1)
    end
  end

  describe "planner reachability" do
    it "is reachable when the category is an InterestCategories key" do
      expect(health_for(template_board(category: "Animals"))).to be_planner_reachable
    end

    it "flags a category the planner can never produce" do
      board = template_board(category: "Dinosaurs")
      health = health_for(board)

      expect(health).not_to be_planner_reachable
      expect(health.problems.join(" ")).to include("Boards::InterestCategories")
    end
  end

  describe "shadowing" do
    # source_for_category returns :seed_set BEFORE it consults FringeTemplates,
    # so a category is shadowed per LEVEL, not globally.
    it "reports the levels whose core set already ships the page" do
      board = template_board(category: "School")
      expect(health_for(board).shadowing_levels).to eq(["extended"])
    end

    it "is not shadowed when no core set ships the page" do
      expect(health_for(template_board(category: "Animals")).shadowing_levels).to be_empty
    end
  end

  describe "duplicate registration" do
    it "flags a category served by more than one board" do
      board = template_board
      health = health_for(board, duplicate_registration: true)

      expect(health).not_to be_healthy
      expect(health.problems.join(" ")).to include("More than one board")
    end
  end
end
