require "rails_helper"

RSpec.describe VocabSets do
  # The seeder imports as User::DEFAULT_ADMIN_ID, so an admin with that id must
  # exist. The authored Core 60 source ships in db/seeds/board_builder_sets/:
  # a 10×6 core home + 8 fringe category pages. (The Keyboard page was removed
  # 2026-06-06 — the keyboard feature isn't built yet.)
  let!(:admin) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

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
      expect { @root = VocabSets.seed_slug!("core-60") }.not_to change { BoardGroup.count }

      expect(@root.name).to eq("Core 60")
      expect(@root.settings["board_builder_robust"]).to be(true)
      expect(@root.settings["board_builder_robust_slug"]).to eq("core-60")

      # Root + 8 fringe pages, all admin-owned and predefined/published.
      admin_boards = Board.where(user_id: admin.id)
      expect(admin_boards.pluck(:name)).to contain_exactly(*CORE_60_BOARD_NAMES)
      expect(admin_boards.all? { |b| b.predefined && b.published }).to be(true)

      # The root's "Food" folder tile links to the imported Food fringe board.
      food_tile = @root.board_images.find_by(label: "Food")
      expect(food_tile.predictive_board_id).to be_present
      expect(Board.find(food_tile.predictive_board_id).name).to eq("Food")
    end

    it "does not create self-link folder tiles on fringe pages" do
      # Each fringe page's own folder is intentionally absent from its nav row
      # (a tile pointing at its own board isn't dynamic — see BoardImage#is_dynamic?).
      root = VocabSets.seed_slug!("core-60")
      food_board = Board.find(root.board_images.find_by(label: "Food").predictive_board_id)
      food_self_links = food_board.board_images.where(predictive_board_id: food_board.id)
      expect(food_self_links).to be_empty
    end

    it "is findable via Boards::RobustSets after seeding" do
      VocabSets.seed_slug!("core-60")
      root = Boards::RobustSets.find_root("core-60")
      expect(root).to be_present
      expect(Boards::RobustSets.slug_for(root)).to eq("core-60")
    end

    it "ships fringe pages for the interest categories it can route into" do
      # The set names some fringe pages after routable interest categories
      # (Food/Feelings/Play) so the wizard drops matching interests there. Other
      # pages (People/Places/Body/Drinks/More) have no matching category yet —
      # interests for those fall through to the auto "My Favorites" page by
      # design (nothing is dropped). This guards the routable pages against drift:
      # if Food/Feelings/Play were renamed, routing would silently break.
      VocabSets.seed_slug!("core-60")

      fringe_names = Board.where(user_id: admin.id).where.not(name: "Core 60").pluck(:name)
      routable = fringe_names.select { |name| Boards::InterestCategories.categories.include?(name) }

      # The authored set's routable category pages.
      expect(routable).to contain_exactly("Food", "Feelings", "Play")
    end

    it "is idempotent — re-seeding doesn't duplicate boards or roots" do
      VocabSets.seed_slug!("core-60")
      expect { VocabSets.seed_slug!("core-60") }.not_to change { Board.where(user_id: admin.id).count }
      expect(Boards::RobustSets.all_roots.count).to eq(1)
    end
  end

  describe "cross-set isolation (#278)" do
    it "seeds disjoint fringe boards per set, each fringe Home resolving to its own root" do
      c60 = VocabSets.seed_slug!("core-60")
      c84 = VocabSets.seed_slug!("core-84")

      c60_people = Board.find(c60.board_images.find_by(label: "People").predictive_board_id)
      c84_people = Board.find(c84.board_images.find_by(label: "People").predictive_board_id)

      # Namespaced ids -> the two sets get distinct fringe boards (the collision
      # made both roots share one People board).
      expect(c60_people.id).not_to eq(c84_people.id)
      expect(c60_people.obf_id).to eq("core-60:people")
      expect(c84_people.obf_id).to eq("core-84:people")

      # Each fringe page's Home tile points at ITS OWN set's root.
      expect(c60_people.board_images.find_by(label: "Home").predictive_board_id).to eq(c60.id)
      expect(c84_people.board_images.find_by(label: "Home").predictive_board_id).to eq(c84.id)
    end

    it "shares no fringe boards between the two seeded sets" do
      c60 = VocabSets.seed_slug!("core-60")
      c84 = VocabSets.seed_slug!("core-84")

      c60_ids = collect_set_board_ids(c60)
      c84_ids = collect_set_board_ids(c84)
      expect(c60_ids & c84_ids).to be_empty
    end
  end

  describe "destructive re-seed sync (#277)" do
    it "prunes a tile that is no longer present in the source OBF on re-seed" do
      root = VocabSets.seed_slug!("core-60")

      # A stale tile from an older OBF revision (e.g. please/thank you/and that
      # #276 removed from the home) — not in the current source.
      create(:board_image, board: root, label: "obsolete_word",
                           image: create(:image, label: "obsolete_word", user_id: admin.id))
      expect(root.board_images.where(label: "obsolete_word")).to exist

      VocabSets.seed_slug!("core-60")
      expect(root.reload.board_images.where(label: "obsolete_word")).not_to exist
    end

    it "keeps authored tiles intact across a re-seed" do
      root = VocabSets.seed_slug!("core-60")
      before_tile_count = root.board_images.count

      VocabSets.seed_slug!("core-60")
      expect(root.reload.board_images.count).to eq(before_tile_count)
    end

    it "destroys an admin board dropped from the manifest (namespaced orphan) on re-seed" do
      VocabSets.seed_slug!("core-60")
      orphan = create(:board, user: admin, obf_id: "core-60:retired", name: "Retired", predefined: true)

      VocabSets.seed_slug!("core-60")
      expect(Board.exists?(orphan.id)).to be(false)
    end

    it "cleans up legacy un-namespaced and removed (keyboard) boards in one re-seed" do
      # Pre-namespacing collision-era fringe board + the Keyboard board removed
      # in #276 — both admin-owned, both stale.
      legacy_people   = create(:board, user: admin, obf_id: "people", name: "People (legacy)", predefined: true)
      legacy_keyboard = create(:board, user: admin, obf_id: "keyboard", name: "Keyboard", predefined: true)

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
  end

  # All admin-owned board ids reachable from a seeded set's root (root + fringe).
  def collect_set_board_ids(root)
    ids = [root.id]
    root.board_images.where.not(predictive_board_id: nil).each do |bi|
      ids << bi.predictive_board_id
    end
    ids.uniq
  end
end
