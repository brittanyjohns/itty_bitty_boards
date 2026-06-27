require "rails_helper"

RSpec.describe VocabSets do
  # The seeder imports as User::DEFAULT_ADMIN_ID, so an admin with that id must
  # exist. The authored Core 60 source ships in db/seeds/board_builder_sets/:
  # a 10×6 core home + 8 fringe category pages. (The Keyboard page was removed
  # 2026-06-06 — the keyboard feature isn't built yet.)
  #
  # Shared across all examples via before_all (test-prof). Each example runs
  # inside a savepoint that rolls back, so modifications don't leak.
  before_all do
    @admin = create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    @c60_root = VocabSets.seed_slug!("core-60")
    @c84_root = VocabSets.seed_slug!("core-84")
  end

  # The authored Core 60 set: root + 8 fringe pages.
  CORE_60_BOARD_NAMES = [
    "Core 60", "People", "Feelings", "Food", "Drinks",
    "Play", "Places", "Body", "More"
  ].freeze

  describe ".available_slugs" do
    it "lists slugs that have a manifest.json" do
      expect(VocabSets.available_slugs).to include("core-60")
    end

    it "filters by the provided list" do
      expect(VocabSets.available_slugs("core-60")).to eq(["core-60"])
      expect(VocabSets.available_slugs("does-not-exist")).to be_empty
    end
  end

  describe ".seed_slug!" do
    it "imports the authored set as a marked, predefined, linked tree (no BoardGroup)" do
      expect(@c60_root.name).to eq("Core 60")
      expect(@c60_root.settings["board_builder_robust"]).to be(true)
      expect(@c60_root.settings["board_builder_robust_slug"]).to eq("core-60")

      c60_boards = Board.where(user_id: @admin.id).where("obf_id LIKE ?", "core-60:%")
                        .or(Board.where(id: @c60_root.id))
      expect(c60_boards.pluck(:name)).to contain_exactly(*CORE_60_BOARD_NAMES)
      expect(c60_boards.all? { |b| b.predefined && b.published }).to be(true)

      food_tile = @c60_root.board_images.find_by(label: "Food")
      expect(food_tile.predictive_board_id).to be_present
      expect(Board.find(food_tile.predictive_board_id).name).to eq("Food")
    end

    it "does not create self-link folder tiles on fringe pages" do
      food_board = Board.find(@c60_root.board_images.find_by(label: "Food").predictive_board_id)
      food_self_links = food_board.board_images.where(predictive_board_id: food_board.id)
      expect(food_self_links).to be_empty
    end

    it "is findable via Boards::RobustSets after seeding" do
      root = Boards::RobustSets.find_root("core-60")
      expect(root).to be_present
      expect(Boards::RobustSets.slug_for(root)).to eq("core-60")
    end

    it "ships fringe pages for the interest categories it can route into" do
      fringe_names = Board.where(user_id: @admin.id).where("obf_id LIKE ?", "core-60:%").pluck(:name)
      routable = fringe_names.select { |name| Boards::InterestCategories.categories.include?(name) }

      expect(routable).to contain_exactly("Food", "Feelings", "Places", "Play")
    end

    it "is idempotent — re-seeding doesn't duplicate boards or roots" do
      expect { VocabSets.seed_slug!("core-60") }.not_to change { Board.where(user_id: @admin.id).count }
      expect(Boards::RobustSets.all_roots.where("settings->>'board_builder_robust_slug' = ?", "core-60").count).to eq(1)
    end
  end

  describe "cross-set isolation (#278)" do
    it "seeds disjoint fringe boards per set, each fringe Home resolving to its own root" do
      c60_people = Board.find(@c60_root.board_images.find_by(label: "People").predictive_board_id)
      c84_people = Board.find(@c84_root.board_images.find_by(label: "People").predictive_board_id)

      expect(c60_people.id).not_to eq(c84_people.id)
      expect(c60_people.obf_id).to eq("core-60:people")
      expect(c84_people.obf_id).to eq("core-84:people")

      expect(c60_people.board_images.find_by(label: "Home").predictive_board_id).to eq(@c60_root.id)
      expect(c84_people.board_images.find_by(label: "Home").predictive_board_id).to eq(@c84_root.id)
    end

    it "shares no fringe boards between the two seeded sets" do
      c60_ids = collect_set_board_ids(@c60_root)
      c84_ids = collect_set_board_ids(@c84_root)
      expect(c60_ids & c84_ids).to be_empty
    end
  end

  describe "destructive re-seed sync (#277)" do
    it "prunes a tile that is no longer present in the source OBF on re-seed" do
      create(:board_image, board: @c60_root, label: "obsolete_word",
                           image: create(:image, label: "obsolete_word", user_id: @admin.id))
      expect(@c60_root.board_images.where(label: "obsolete_word")).to exist

      VocabSets.seed_slug!("core-60")
      expect(@c60_root.reload.board_images.where(label: "obsolete_word")).not_to exist
    end

    it "keeps authored tiles intact across a re-seed" do
      before_tile_count = @c60_root.board_images.count

      VocabSets.seed_slug!("core-60")
      expect(@c60_root.reload.board_images.count).to eq(before_tile_count)
    end

    it "destroys an admin board dropped from the manifest (namespaced orphan) on re-seed" do
      orphan = create(:board, user: @admin, obf_id: "core-60:retired", name: "Retired", predefined: true)

      VocabSets.seed_slug!("core-60")
      expect(Board.exists?(orphan.id)).to be(false)
    end

    it "cleans up legacy un-namespaced and removed (keyboard) boards in one re-seed" do
      legacy_people   = create(:board, user: @admin, obf_id: "people", name: "People (legacy)", predefined: true)
      legacy_keyboard = create(:board, user: @admin, obf_id: "keyboard", name: "Keyboard", predefined: true)

      VocabSets.seed_slug!("core-60")

      expect(Board.exists?(legacy_people.id)).to be(false)
      expect(Board.exists?(legacy_keyboard.id)).to be(false)
    end

    it "leaves another admin's lookalike boards untouched (scoped to DEFAULT_ADMIN_ID)" do
      other = create(:user)
      theirs = create(:board, user: other, obf_id: "people", name: "People")

      VocabSets.seed_slug!("core-60")
      expect(Board.exists?(theirs.id)).to be(true)
    end

    # The "extra all done" bug: a prior buggy re-seed appended a second tile for
    # a still-authored label (prune_removed_tiles! keeps both). A re-seed now
    # collapses the duplicate, keeping the authored tile.
    it "collapses a duplicate authored tile appended by a prior buggy re-seed" do
      authored = @c60_root.board_images.find_by(label: "all done")
      expect(authored).to be_present

      dup = create(:board_image, board: @c60_root, label: "all done", position: 999,
                                 image: create(:image, label: "all done", user_id: @admin.id))
      expect(@c60_root.board_images.where(label: "all done").count).to eq(2)

      VocabSets.seed_slug!("core-60")

      expect(@c60_root.reload.board_images.where(label: "all done").count).to eq(1)
      expect(@c60_root.board_images.exists?(authored.id)).to be(true)
      expect(@c60_root.board_images.exists?(dup.id)).to be(false)
    end
  end

  describe "layout self-heal on re-seed (repair_layout!)" do
    # Count tiles whose lg cell collides with an earlier tile's lg cell.
    def lg_overlaps(board)
      seen = {}
      count = 0
      board.reload.board_images.each do |bi|
        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil? || cell["x"].nil?

        key = [cell["x"].to_i, cell["y"].to_i]
        count += 1 if seen[key]
        seen[key] = true
      end
      count
    end

    # The historical re-seed bug could leave two tiles parked on one cell while
    # another cell sat empty (core-84 "wait" on "again"), so the board rendered
    # with a tile hidden behind another. Re-seeding must restore each surviving
    # tile to its authored cell — no two tiles sharing a cell afterward.
    it "re-pins overlapping tiles to their authored cells on re-seed" do
      authored_count = @c84_root.board_images.count
      again = @c84_root.board_images.find_by(label: "again")
      wait  = @c84_root.board_images.find_by(label: "wait")
      expect(again).to be_present
      expect(wait).to be_present

      # Simulate the corruption: drop "wait" onto "again"'s cell.
      again_cell = again.reload.layout["lg"]
      wait.update_column(:layout, wait.layout.merge(
        "lg" => again_cell.merge("i" => wait.id.to_s),
        "md" => again_cell.merge("i" => wait.id.to_s),
        "sm" => again_cell.merge("i" => wait.id.to_s),
      ))
      @c84_root.update_board_layout("lg")
      expect(lg_overlaps(@c84_root)).to be >= 1

      VocabSets.seed_slug!("core-84")

      expect(lg_overlaps(@c84_root)).to eq(0)
      expect(@c84_root.reload.board_images.count).to eq(authored_count)
    end

    it "is a no-op on an already-clean set (no overlaps introduced)" do
      expect(lg_overlaps(@c84_root)).to eq(0)
      VocabSets.seed_slug!("core-84")
      expect(lg_overlaps(@c84_root)).to eq(0)
    end
  end

  describe "tile colors from authored part_of_speech (#279)" do
    EXPECTED_TILES = {
      "I" => { pos: "pronoun", hex: "#FFEA75" },
      "want" => { pos: "verb", hex: "#A1F571" },
      "what" => { pos: "question", hex: "#A07AFF" },
    }.freeze

    def expect_authored_colors(board)
      EXPECTED_TILES.each do |label, expected|
        tile = board.board_images.find_by(label: label)
        expect(tile).to be_present, "expected a '#{label}' tile on #{board.name}"
        expect(tile.part_of_speech).to eq(expected[:pos]),
          "expected '#{label}' part_of_speech #{expected[:pos]}, got #{tile.part_of_speech}"
        expect(tile.bg_color).to eq(expected[:hex]),
          "expected '#{label}' bg_color #{expected[:hex]}, got #{tile.bg_color}"
      end
    end

    it "colors seeded home tiles per the authored OBF part_of_speech" do
      expect_authored_colors(@c60_root)
    end

    it "restores authored colors on re-seed after a tile was mangled" do
      tile = @c60_root.board_images.find_by(label: "I")
      tile.update_columns(part_of_speech: "noun", bg_color: "#FFFFFF")

      VocabSets.seed_slug!("core-60")
      expect_authored_colors(@c60_root.reload)
    end

    it "heals a stale bg_color on re-seed even when part_of_speech is already right" do
      tile = @c60_root.board_images.find_by(label: "I")
      tile.update_columns(bg_color: "#FFFFFF")

      VocabSets.seed_slug!("core-60")
      expect(@c60_root.reload.board_images.find_by(label: "I").bg_color).to eq("#FFEA75")
    end

    it "never overwrites a non-blank part_of_speech on the shared Image record" do
      image = @c60_root.board_images.find_by(label: "I").image
      image.update_column(:part_of_speech, "noun")

      VocabSets.seed_slug!("core-60")
      expect(image.reload.part_of_speech).to eq("noun")
      expect(@c60_root.reload.board_images.find_by(label: "I").part_of_speech).to eq("pronoun")
    end

    it "backfills a blank Image part_of_speech from the authored OBF" do
      image = @c60_root.board_images.find_by(label: "I").image
      image.update_column(:part_of_speech, nil)

      VocabSets.seed_slug!("core-60")
      expect(image.reload.part_of_speech).to eq("pronoun")
    end
  end

  describe "one-page display (no scrolling)" do
    def c60_boards
      Board.where(user_id: @admin.id).where("obf_id LIKE ?", "core-60:%")
           .or(Board.where(id: @c60_root.id))
    end

    it "marks every seeded board disable_scroll so the native page fits it on one screen" do
      boards = c60_boards
      expect(boards).not_to be_empty
      boards.each do |board|
        expect(board.settings["disable_scroll"]).to be(true),
          "expected #{board.name} to have settings['disable_scroll'] = true"
      end
    end

    it "keeps disable_scroll set across a re-seed" do
      VocabSets.seed_slug!("core-60")

      expect(c60_boards.all? { |b| b.settings["disable_scroll"] == true }).to be(true)
    end

    it "preserves each home board's authored grid (Core 60: 10×6, Core 84: 12×7)" do
      expect(@c60_root.large_screen_columns).to eq(10)
      expect(@c60_root.large_screen_rows).to eq(6)
      expect(@c84_root.large_screen_columns).to eq(12)
      expect(@c84_root.large_screen_rows).to eq(7)
    end
  end

  describe "finalized 60-tile root (Drinks wired, this/that added)" do
    it "places exactly 60 tiles on the Core 60 home board" do
      expect(@c60_root.board_images.count).to eq(60)
    end

    it "wires the Drinks folder tile to the seeded Drinks board" do
      drinks_tile = @c60_root.board_images.find_by(label: "Drinks")
      expect(drinks_tile).to be_present
      expect(drinks_tile.predictive_board_id).to be_present
      expect(Board.find(drinks_tile.predictive_board_id).name).to eq("Drinks")
    end

    it "adds the this/that core word tiles that fill the home grid to 60" do
      expect(@c60_root.board_images.pluck(:label)).to include("this", "that")
    end

    it "links all eight category folders from the home board" do
      folder_names = @c60_root.board_images.where.not(predictive_board_id: nil).map do |bi|
        Board.find(bi.predictive_board_id).name
      end
      expect(folder_names).to contain_exactly(
        "People", "Feelings", "Food", "Drinks", "Play", "Places", "Body", "More"
      )
    end
  end

  describe "finalized 84-tile root (Drinks wired, this/that added)" do
    it "places exactly 84 tiles on the Core 84 home board" do
      expect(@c84_root.board_images.count).to eq(84)
    end

    it "wires the Drinks folder tile to the seeded Drinks board" do
      drinks_tile = @c84_root.board_images.find_by(label: "Drinks")
      expect(drinks_tile).to be_present
      expect(drinks_tile.predictive_board_id).to be_present
      expect(Board.find(drinks_tile.predictive_board_id).name).to eq("Drinks")
    end

    it "adds the this/that core word tiles that fill the home grid to 84" do
      expect(@c84_root.board_images.pluck(:label)).to include("this", "that")
    end

    it "links all eleven category folders from the home board" do
      folder_names = @c84_root.board_images.where.not(predictive_board_id: nil).map do |bi|
        Board.find(bi.predictive_board_id).name
      end
      expect(folder_names).to contain_exactly(
        "People", "Feelings", "Food", "Drinks", "Play", "Places", "Body", "More",
        "School", "Time", "Describe"
      )
    end
  end

  def collect_set_board_ids(root)
    ids = [root.id]
    root.board_images.where.not(predictive_board_id: nil).each do |bi|
      ids << bi.predictive_board_id
    end
    ids.uniq
  end
end
