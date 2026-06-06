require "rails_helper"

RSpec.describe VocabSets do
  # The seeder imports as User::DEFAULT_ADMIN_ID, so an admin with that id must
  # exist. The authored Core 60 source ships in db/seeds/board_builder_sets/:
  # a 10×6 core home + 9 fringe category pages.
  let!(:admin) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  # The authored Core 60 set: root + 9 fringe pages.
  CORE_60_BOARD_NAMES = [
    "Core 60", "People", "Feelings", "Food", "Drinks",
    "Play", "Places", "Body", "More", "Keyboard"
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

      # Root + 9 fringe pages, all admin-owned and predefined/published.
      admin_boards = Board.where(user_id: admin.id)
      expect(admin_boards.pluck(:name)).to contain_exactly(*CORE_60_BOARD_NAMES)
      expect(admin_boards.all? { |b| b.predefined && b.published }).to be(true)

      # The root's "Food" folder tile links to the imported Food fringe board.
      food_tile = @root.board_images.find_by(label: "Food")
      expect(food_tile.predictive_board_id).to be_present
      expect(Board.find(food_tile.predictive_board_id).name).to eq("Food")
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
      # pages (People/Places/Body/Drinks/Keyboard/More) have no matching category
      # yet — interests for those fall through to the auto "My Favorites" page by
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
end
