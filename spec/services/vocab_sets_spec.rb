require "rails_helper"

RSpec.describe VocabSets do
  # The seeder imports as User::DEFAULT_ADMIN_ID, so an admin with that id must
  # exist. The placeholder Core 60 source ships in db/seeds/board_builder_sets/.
  let!(:admin) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

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
    it "imports the placeholder set as a marked, predefined, linked tree (no BoardGroup)" do
      expect { @root = VocabSets.seed_slug!("core-60") }.not_to change { BoardGroup.count }

      expect(@root.name).to eq("Core 60")
      expect(@root.settings["board_builder_robust"]).to be(true)
      expect(@root.settings["board_builder_robust_slug"]).to eq("core-60")

      # Root + 3 fringe pages, all admin-owned and predefined/published.
      admin_boards = Board.where(user_id: admin.id)
      expect(admin_boards.count).to eq(4)
      expect(admin_boards.pluck(:name)).to contain_exactly("Core 60", "Food", "Feelings", "Play")
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

    it "names every fringe page after a recognized interest category so routing lands" do
      # Guards against content drift: if a fringe page is renamed to something
      # InterestCategories doesn't know, interests for it silently fall to
      # "My Favorites". The placeholder's pages are Food/Feelings/Play.
      VocabSets.seed_slug!("core-60")

      fringe_names = Board.where(user_id: admin.id).where.not(name: "Core 60").pluck(:name)
      expect(fringe_names).not_to be_empty
      fringe_names.each do |name|
        expect(Boards::InterestCategories.categories).to include(name),
                                                          "fringe page #{name.inspect} is not a routable interest category"
      end
    end

    it "is idempotent — re-seeding doesn't duplicate boards or roots" do
      VocabSets.seed_slug!("core-60")
      expect { VocabSets.seed_slug!("core-60") }.not_to change { Board.where(user_id: admin.id).count }
      expect(Boards::RobustSets.all_roots.count).to eq(1)
    end
  end
end
