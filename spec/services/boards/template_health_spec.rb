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

  # The failure this exists to catch: the authored .obf files were re-authored
  # from 3x4/12 words to 4x10/40 in #747 and the database rows were never
  # re-seeded, so production served a template three quarters smaller than its
  # source — and reported "healthy", because the only source check asked whether
  # a FILE existed, never whether the row still matched it. A stale template is
  # cloned verbatim into every set built from it.
  describe "drift from the authored source" do
    def sources_with(category:, core_template:, rows:, columns:, tile_count:)
      instance_double(
        Boards::FringeSources,
        for: Boards::FringeSources::Source.new(
          path: "/seed/#{core_template}/animals.obf",
          relative_path: "#{core_template}/animals.obf",
          category: category, core_template: core_template,
          rows: rows, columns: columns, tile_count: tile_count,
        ),
        for_category: [:a_source],
        variants_for: Boards::FringeTemplates::VARIANTS,
      )
    end

    it "flags a board whose grid and tile count no longer match its .obf" do
      board = template_board(columns: 4, tiles: 2)
      health = health_for(board, core_template: "core-60",
                                 sources: sources_with(category: "Animals", core_template: "core-60",
                                                       rows: 4, columns: 10, tile_count: 40))

      expect(health).to be_stale_vs_source
      expect(health).not_to be_healthy
      expect(health.status).to eq("error")
      expect(health.problems.join(" ")).to include("core-60/animals.obf authors 40 tiles in a 4x10 grid")
      expect(health.problems.join(" ")).to include("Re-seed it")
    end

    it "stays healthy when the board matches its .obf" do
      board = template_board(columns: 2, tiles: 2)
      health = health_for(board, core_template: "core-60",
                                 sources: sources_with(category: "Animals", core_template: "core-60",
                                                       rows: 1, columns: 2, tile_count: 2))

      expect(health).not_to be_stale_vs_source
      expect(health.problems.join(" ")).not_to include("Stale")
    end

    # Boards::FringeSources#for answers nil when it cannot tell which authored
    # file a row belongs to. Comparing against a guess would report a drift that
    # is not there.
    it "says nothing when there is no unambiguous source" do
      board = template_board(columns: 4, tiles: 2)
      sources = instance_double(Boards::FringeSources, for: nil, for_category: [:a_source],
                                                       variants_for: Boards::FringeTemplates::VARIANTS)
      health = health_for(board, sources: sources)

      expect(health).not_to be_stale_vs_source
      expect(health.problems.join(" ")).not_to include("Stale")
    end

    it "asks for a core set on a template that records none" do
      board = template_board
      sources = instance_double(Boards::FringeSources, for: nil, for_category: [:a_source],
                                                       variants_for: Boards::FringeTemplates::VARIANTS)
      health = health_for(board, sources: sources)

      expect(health.notes.join(" ")).to include("No core set recorded")
    end

    # Not a fault — Boards::FringeTemplates.find falls back across core sets
    # rather than charging AI credits — but the wrong-width page it produces
    # should be nameable from the registry.
    it "names a category authored for only one core set" do
      board = template_board
      sources = instance_double(
        Boards::FringeSources,
        for: nil, for_category: [:a_source], variants_for: ["core-60"],
      )
      health = health_for(board, core_template: "core-60", sources: sources)

      expect(health.missing_variants).to eq(["core-84"])
      expect(health.notes.join(" ")).to include("core-84 build clones a page sized for the other grid")
    end
  end
end
