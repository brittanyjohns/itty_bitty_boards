# frozen_string_literal: true

require "rails_helper"

# The board slots the board-limit gate reserves before a Board Builder run. A
# level is sized from the REQUEST — the planner decides which pages the job will
# add, so the reservation is what this build can create, not the most any build
# at that level could. The "real build" examples at the bottom hold that
# arithmetic to what BuildBoardSetJob actually persists.
RSpec.describe Boards::BuilderSetSize do
  def seed_pages(core)
    Boards::StructurePlanner::SEED_SET_PAGES.fetch(core).size
  end

  # Two interests explicitly filed under a category the seed set has no page
  # for, so the planner adds one non-seed page (two clears MIN_AI_PAGE_INTERESTS).
  def interests_for(category, words)
    { interests: words, explicit_categories: words.to_h { |w| [w, category] } }
  end

  describe ".base_cost" do
    it "is the root plus the whole authored seed set — what a level builds with no interests" do
      expect(described_class.base_cost("starter")).to eq(1 + seed_pages("core-60"))
      expect(described_class.base_cost("standard")).to eq(1 + seed_pages("core-60"))
      expect(described_class.base_cost("extended")).to eq(1 + seed_pages("core-84"))
    end

    it "keeps the shipped level sizes at 9 / 9 / 12" do
      expect(described_class.base_cost("starter")).to eq(9)
      expect(described_class.base_cost("standard")).to eq(9)
      expect(described_class.base_cost("extended")).to eq(12)
    end

    it "never shrinks as the level grows" do
      sizes = Boards::StructurePlanner::LEVEL_KEYS.map { |k| described_class.base_cost(k) }
      expect(sizes).to eq(sizes.sort)
    end

    it "is case- and symbol-insensitive" do
      expect(described_class.base_cost(:Extended)).to eq(described_class.base_cost("extended"))
    end

    # A StarterBlueprints tree is fully known up front, so it is sized from the
    # tree itself: its root, one board per folder tile, plus the "My Favorites"
    # page BlueprintAssembler#route_interests! can append.
    describe "blueprint templates" do
      it "sizes Quick Start (home) at 5: root + Food + Feelings + Play + My Favorites" do
        expect(described_class.base_cost("home")).to eq(5)
      end

      it "sizes daily_routine at 3: root + Bathroom + My Favorites" do
        expect(described_class.base_cost("daily_routine")).to eq(3)
      end

      it "is case- and symbol-insensitive for a blueprint key too" do
        expect(described_class.base_cost(:HOME)).to eq(5)
      end

      it "derives the count from the tree, so a new blueprint sizes itself" do
        tree = {
          name: "Nested",
          tiles: [
            { label: "hi" },
            { label: "A", children: { name: "A", tiles: [
              { label: "a1" },
              { label: "B", children: { name: "B", tiles: [{ label: "b1" }] } },
            ] } },
            { label: "C", children: { name: "C", tiles: [{ label: "c1" }] } },
          ],
        }
        stub_const("Boards::StarterBlueprints::TEMPLATES", { "nested" => tree })

        # root + A + B (nested) + C + favorites
        expect(described_class.base_cost("nested")).to eq(5)
      end
    end

    # A robust-set slug clones a whole authored tree whose size isn't knowable
    # without the seed, so it keeps the roomy bound.
    it "falls back to the roomy legacy bound for a robust-set slug or an unknown key" do
      expect(described_class.base_cost("core-60")).to eq(described_class.legacy_worst_case)
      expect(described_class.base_cost("core-84")).to eq(described_class.legacy_worst_case)
      expect(described_class.base_cost(nil)).to eq(described_class.legacy_worst_case)
      expect(described_class.legacy_worst_case).to eq(35)
    end

    it "does not resolve a robust-set slug as a blueprint" do
      expect(Boards::StarterBlueprints.tree_for("core-60")).to be_nil
      expect(Boards::StarterBlueprints.tree_for("core-84")).to be_nil
    end
  end

  describe ".for_request" do
    it "is the base cost when the request carries no interests" do
      Boards::StructurePlanner::LEVEL_KEYS.each do |level|
        expect(described_class.for_request(level)).to eq(described_class.base_cost(level)), level
      end
    end

    it "reserves My Favorites for any interest, since a leftover word can land there" do
      expect(described_class.for_request("extended", interests: ["zorblax"]))
        .to eq(described_class.base_cost("extended") + 1)
    end

    it "adds nothing past My Favorites for interests that land on a seed page" do
      expect(described_class.for_request("extended", **interests_for("Food", %w[pizza noodles])))
        .to eq(described_class.base_cost("extended") + 1)
    end

    it "adds one board for each non-seed page the planner adds" do
      expect(described_class.for_request("extended", **interests_for("Vehicles", %w[rocket tractor])))
        .to eq(described_class.base_cost("extended") + 1 + 1)
    end

    it "never reserves past root + seed set + the level's max_pages + My Favorites" do
      categories = (1..10).map { |i| "Topic #{i}" }
      interests = categories.flat_map { |c| ["#{c} a", "#{c} b"] }
      explicit = categories.each_with_object({}) do |c, map|
        map["#{c} a"] = c
        map["#{c} b"] = c
      end

      level = Boards::StructurePlanner::LEVELS.fetch("starter")
      expect(described_class.for_request("starter", interests: interests, explicit_categories: explicit))
        .to eq(1 + seed_pages("core-60") + level[:max_pages] + 1)
    end

    it "sizes a blueprint from its tree regardless of interests" do
      expect(described_class.for_request("home", interests: %w[grandma backpack])).to eq(5)
    end
  end

  # The load-bearing ones: if a real build ever persists more boards than the
  # gate reserved, a user can overrun their cap. This is what catches a new seed
  # page or job step the arithmetic above didn't hear about.
  describe "against a real build", type: :request do
    let(:user) { create(:user, settings: { "board_limit" => 500 }) }
    let(:communicator) { create(:child_account, user: user) }
    let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

    before { allow_any_instance_of(Grover).to receive(:to_png).and_return(ChunkyPNG::Image.new(1, 1).to_blob) }

    # A stand-in for `bin/rails vocab_sets:seed`: an admin-owned Core 84 root
    # with every authored fringe page, so SeededSetCloner actually clones a set
    # and the bound is measured against real work rather than a bare root.
    # RobustSets.all_roots is scoped to the seeder (DEFAULT_ADMIN_ID +
    # predefined), so the fixture has to be owned that way.
    def seed_core_84!
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      root = create(:board, user: admin, name: "Core 84", predefined: true, published: true)

      Boards::StructurePlanner::SEED_SET_PAGES.fetch("core-84").each do |page_name|
        page = create(:board, user: admin, name: page_name, predefined: true, published: true)
        create(:board_image, board: page, label: page_name.downcase,
                             image: create(:image, label: page_name.downcase, user_id: admin.id))
        tile = create(:board_image, board: root, label: page_name, display_label: page_name,
                                    image: create(:image, label: page_name, user_id: admin.id))
        tile.update!(predictive_board_id: page.id)
      end

      Boards::RobustSets.mark_root!(root, "core-84")
      root
    end

    # include_phrases: false is what the app sends for every non-admin user.
    def build_extended!(interests: [])
      post "/api/v1/board_builder",
           params: { communicator_id: communicator.id, level: "extended",
                     interests: interests, include_phrases: false }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)
      BuildBoardSetJob.drain
      User.find(user.id).countable_board_count
    end

    it "reserves exactly what an extended build with no interests persists" do
      seed_core_84!

      expect(build_extended!).to eq(described_class.for_request("extended"))
    end

    it "reserves exactly what an extended build with an off-topic interest persists" do
      seed_core_84!

      expect(build_extended!(interests: ["zorblax"]))
        .to eq(described_class.for_request("extended", interests: ["zorblax"]))
    end

    it "bounds what an extended build with mixed interests persists" do
      seed_core_84!

      count = build_extended!(interests: %w[dinosaurs pizza])
      expect(count).to be > 1
      expect(count).to be <= described_class.for_request("extended", interests: %w[dinosaurs pizza])
    end

    # Quick Start is the one set a Free account can hold, and it is sized at 5
    # rather than 4 precisely because off-topic interests add "My Favorites".
    # Build that exact path and prove the reservation holds.
    it "bounds what a Quick Start (home) build with off-topic interests persists" do
      post "/api/v1/board_builder",
           params: { communicator_id: communicator.id, level: "home",
                     interests: ["grandma", "backpack"] }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)
      BuildBoardSetJob.drain

      root = Board.find(JSON.parse(response.body)["id"])
      expect(root.board_images.map(&:display_label)).to include("My Favorites")

      fresh = User.find(user.id)
      expect(fresh.countable_board_count).to eq(5)
      expect(fresh.countable_board_count).to be <= described_class.for_request("home")
    end
  end
end
