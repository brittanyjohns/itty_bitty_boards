require "rails_helper"

RSpec.describe Boards::SeededSetCloner do
  # Shared source set — built once via before_all. Each example's clones and
  # modifications run inside a savepoint that auto-rolls back.
  before_all do
    @admin = create(:admin_user)
    @source = build_source_set!(@admin)
  end

  # Fresh owner + communicator per example (clones belong to them and get
  # rolled back; the shared source set survives).
  let(:owner) { create(:user) }
  let(:communicator) { create(:child_account, user: owner) }

  def build_source_set!(admin_user)
    root     = create(:board, user: admin_user, name: "Core 60", predefined: true, published: true)
    food     = create(:board, user: admin_user, name: "Food", predefined: true, published: true)
    feelings = create(:board, user: admin_user, name: "Feelings", predefined: true, published: true)

    %w[I want help].each do |label|
      create(:board_image, board: root, label: label, image: create(:image, label: label, user_id: admin_user.id))
    end
    food_tile = create(:board_image, board: root, label: "Food",
                                     image: create(:image, label: "Food", user_id: admin_user.id))
    food_tile.update!(predictive_board_id: food.id)
    feelings_tile = create(:board_image, board: root, label: "Feelings",
                                         image: create(:image, label: "Feelings", user_id: admin_user.id))
    feelings_tile.update!(predictive_board_id: feelings.id)

    %w[apple banana].each do |label|
      create(:board_image, board: food, label: label, image: create(:image, label: label, user_id: admin_user.id))
    end
    %w[happy sad].each do |label|
      create(:board_image, board: feelings, label: label, image: create(:image, label: label, user_id: admin_user.id))
    end

    back = create(:board_image, board: feelings, label: "home",
                                image: create(:image, label: "home", user_id: admin_user.id))
    back.update!(predictive_board_id: root.id)

    { root: root, food: food, feelings: feelings, food_tile: food_tile, feelings_tile: feelings_tile }
  end

  describe "#call" do
    it "clones the linked set for the owner and marks builder metadata (root + fringe)" do
      # The cloner builds + marks the set; the "counts as one Board Set" property
      # now lives in the builder BoardGroup the controller/job attaches (#407),
      # so this asserts the clone structure + markers, not countable_board_count.
      @root = described_class.new(@source[:root], communicator: communicator).call

      expect(@root.user_id).to eq(owner.id)
      expect(@root.predefined).to be(false)
      expect(@root.settings["builder_root"]).to be(true)

      owner_boards = owner.boards
      expect(owner_boards.count).to eq(3)
      fringe = owner_boards.where("COALESCE((settings->>'builder_child')::boolean, false)")
      expect(fringe.count).to eq(2)
      expect(fringe.pluck(:name)).to contain_exactly("Food", "Feelings")
    end

    it "rewires folder tiles to the cloned fringe boards and nulls out-of-set pointers" do
      root = described_class.new(@source[:root], communicator: communicator).call

      cloned_food = owner.boards.find_by(name: "Food")
      cloned_feelings = owner.boards.find_by(name: "Feelings")

      food_tile = root.board_images.find_by(label: "Food")
      expect(food_tile.predictive_board_id).to eq(cloned_food.id)

      home_tile = cloned_feelings.board_images.find_by(label: "home")
      expect(home_tile.predictive_board_id).to eq(root.id)

      source_ids = [@source[:root].id, @source[:food].id, @source[:feelings].id]
      cloned_predictive = owner.boards.flat_map { |b| b.board_images.pluck(:predictive_board_id) }.compact
      expect(cloned_predictive & source_ids).to be_empty
    end

    it "attaches exactly one favorite ChildBoard (the root), none for fringe" do
      root = described_class.new(@source[:root], communicator: communicator).call

      child_boards = communicator.child_boards.reload
      expect(child_boards.count).to eq(1)
      expect(child_boards.first.board_id).to eq(root.id)
      expect(child_boards.first.favorite).to be(true)
    end

    it "routes interests into matching cloned fringe pages" do
      root = described_class.new(
        @source[:root], communicator: communicator, interests: ["apple", "happy"]
      ).call

      cloned_food = owner.boards.find_by(name: "Food")
      cloned_feelings = owner.boards.find_by(name: "Feelings")

      expect(cloned_food.board_images.where(label: "apple").count).to eq(1)
      expect(cloned_feelings.board_images.where(label: "happy").count).to eq(1)
    end

    it "upgrades blank tiles on cloned FRINGE pages to curated art (not just the root)" do
      # The seed's "apple" tile points at an art-less admin image. A curated
      # art-bearing "apple" image exists in the public library (DEFAULT_ADMIN_ID)
      # — the cloned Food page tile should be re-pointed to it, same as root
      # tiles already were.
      default_admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      arted_apple = create(:image, label: "apple", user_id: default_admin.id, is_private: false)
      create(:doc, documentable: arted_apple, user: default_admin)

      root = described_class.new(@source[:root], communicator: communicator).call

      cloned_food = owner.boards.find_by(name: "Food")
      apple_tile  = cloned_food.board_images.find_by(label: "apple")

      expect(apple_tile.image_id).to eq(arted_apple.id)
      expect(Boards::ImageResolver.art?(apple_tile.image)).to be(true)
    end

    it "adds a brand-new food interest to the cloned Food page" do
      root = described_class.new(
        @source[:root], communicator: communicator, interests: ["pizza"]
      ).call

      cloned_food = owner.boards.find_by(name: "Food")
      expect(cloned_food.board_images.map(&:label)).to include("pizza")
    end

    it "routes unmatched interests into a created, linked, builder_child 'My Favorites'" do
      root = described_class.new(
        @source[:root], communicator: communicator, interests: ["grandma"]
      ).call

      favorites = owner.boards.find_by(name: "My Favorites")
      expect(favorites).to be_present
      expect(favorites.settings["builder_child"]).to be(true)
      expect(favorites.board_images.map(&:label)).to include("grandma")

      fav_tile = root.board_images.find_by(label: "My Favorites")
      expect(fav_tile.predictive_board_id).to eq(favorites.id)
    end

    it "queues AI art for a novel interest word with no existing symbol" do
      expect(GenerateImagesJob).to receive(:perform_async).with(kind_of(Array), kind_of(Integer)).at_least(:once)

      described_class.new(@source[:root], communicator: communicator, interests: ["dinosaurs"]).call
    end

    it "does not queue art when the interest already exists on the fringe" do
      expect(GenerateImagesJob).not_to receive(:perform_async)

      described_class.new(@source[:root], communicator: communicator, interests: ["apple"]).call
    end

    it "does not mutate the source seed set" do
      described_class.new(@source[:root], communicator: communicator, interests: ["pizza"]).call

      expect(@source[:root].reload.predefined).to be(true)
      expect(@source[:food_tile].reload.predictive_board_id).to eq(@source[:food].id)
      expect(Board.where(user_id: @admin.id).count).to eq(3)
      expect(@source[:food].reload.board_images.map { |bi| bi.image.label }).to contain_exactly("apple", "banana")
    end

    context "with exclude_fringe:" do
      it "skips excluded fringe boards from the clone" do
        root = described_class.new(
          @source[:root], communicator: communicator,
          exclude_fringe: ["Food"],
        ).call

        expect(owner.boards.find_by(name: "Food")).to be_nil
        expect(owner.boards.find_by(name: "Feelings")).to be_present

        food_tile = root.board_images.find_by(label: "Food")
        expect(food_tile.predictive_board_id).to be_nil
      end

      it "is case-insensitive" do
        described_class.new(
          @source[:root], communicator: communicator,
          exclude_fringe: ["food"],
        ).call

        expect(owner.boards.find_by(name: "Food")).to be_nil
      end

      it "never excludes the root" do
        root = described_class.new(
          @source[:root], communicator: communicator,
          exclude_fringe: ["Core 60"],
        ).call

        expect(root).to be_present
        expect(root.name).to eq("Core 60")
      end
    end

    it "raises CloneError when the communicator has no owning user" do
      orphan = build(:child_account)
      allow(orphan).to receive(:owner).and_return(nil)
      allow(orphan).to receive(:user).and_return(nil)

      expect {
        described_class.new(@source[:root], communicator: orphan).call
      }.to raise_error(Boards::SeededSetCloner::CloneError)
    end

    context "with an adopted root (async path via BuildBoardSetJob)" do
      def precreated_root(name: "Core 60")
        root = Board.new(name: name, user: owner)
        root.board_type = "dynamic"
        root.assign_parent
        root.generate_unique_slug
        root.settings = (root.settings || {}).merge("builder_root" => true)
        root.status = "building_board"
        root.save!
        communicator.child_boards.create!(board: root, created_by_id: owner.id).update!(favorite: true)
        root
      end

      it "clones the source root's tiles INTO the adopted root and rewires links to the clones" do
        root = precreated_root

        returned = described_class.new(@source[:root], communicator: communicator, root: root).call

        expect(returned.id).to eq(root.id)
        root.reload
        expect(root.board_images.map(&:label)).to include("I", "want", "help", "Food", "Feelings")

        cloned_food = owner.boards.find_by(name: "Food")
        food_tile = root.board_images.find_by(label: "Food")
        expect(food_tile.predictive_board_id).to eq(cloned_food.id)

        cloned_feelings = owner.boards.find_by(name: "Feelings")
        expect(cloned_feelings.board_images.find_by(label: "home").predictive_board_id).to eq(root.id)

        expect(owner.boards.count).to eq(3)
      end

      it "preserves the adopted root's identity, does not re-attach, and never inherits the robust catalog markers" do
        Boards::RobustSets.mark_root!(@source[:root], "core-60")
        root = precreated_root
        original_slug = root.slug

        expect {
          described_class.new(@source[:root], communicator: communicator, root: root).call
        }.not_to change { communicator.child_boards.count }

        root.reload
        expect(root.name).to eq("Core 60")
        expect(root.slug).to eq(original_slug)
        expect(root.user_id).to eq(owner.id)
        expect(root.status).to eq("building_board")
        expect(root.settings["builder_root"]).to be(true)
        expect(Boards::RobustSets.all_roots.pluck(:id)).to contain_exactly(@source[:root].id)
      end

      it "routes interests into the cloned fringe pages under the adopted root" do
        root = precreated_root

        described_class.new(
          @source[:root], communicator: communicator, interests: ["pizza", "grandma"], root: root
        ).call

        cloned_food = owner.boards.find_by(name: "Food")
        expect(cloned_food.board_images.map(&:label)).to include("pizza")

        favorites = owner.boards.find_by(name: "My Favorites")
        expect(favorites.board_images.map(&:label)).to include("grandma")
        fav_tile = root.reload.board_images.find_by(label: "My Favorites")
        expect(fav_tile.predictive_board_id).to eq(favorites.id)
      end

      it "rolls back fringe clones/tiles on failure but leaves the adopted root" do
        root = precreated_root
        allow_any_instance_of(described_class)
          .to receive(:route_interests!).and_raise(Boards::SeededSetCloner::CloneError, "boom")

        expect {
          described_class.new(@source[:root], communicator: communicator, root: root).call
        }.to raise_error(Boards::SeededSetCloner::CloneError)

        expect(root.reload).to be_persisted
        expect(root.board_images.count).to eq(0)
        expect(owner.boards.where.not(id: root.id).count).to eq(0)
      end
    end
  end

  # Regression for #278: seed BOTH real sets, then clone each.
  describe "cloning a real seeded robust set" do
    before_all do
      register_openai_webmock_stub!
      register_external_webmock_stubs!
      @seed_admin = create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      VocabSets.seed_slug!("core-60")
      VocabSets.seed_slug!("core-84")
    end

    %w[core-60 core-84].each do |slug|
      it "gives #{slug} clones a working Home tile on every fringe page" do
        source_root = Boards::RobustSets.find_root(slug)
        cloned_root = described_class.new(source_root, communicator: communicator).call

        fringe = owner.boards.where("COALESCE((settings->>'builder_child')::boolean, false)")
        expect(fringe.count).to be > 0

        fringe.each do |board|
          home = board.board_images.find_by(label: "Home")
          expect(home).to be_present, "expected fringe '#{board.name}' to have a Home tile"
          expect(home.predictive_board_id).to eq(cloned_root.id)
        end
      end
    end

    it "carries the authored part_of_speech colors onto the cloned set" do
      source_root = Boards::RobustSets.find_root("core-60")
      cloned_root = described_class.new(source_root, communicator: communicator).call

      { "I" => ["pronoun", "#FFEA75"],
        "want" => ["verb", "#A1F571"],
        "what" => ["question", "#A07AFF"] }.each do |label, (pos, hex)|
        tile = cloned_root.board_images.find_by(label: label)
        expect(tile).to be_present, "expected a cloned '#{label}' tile"
        expect(tile.part_of_speech).to eq(pos)
        expect(tile.bg_color).to eq(hex)
      end
    end

    it "carries disable_scroll (one-page display) onto every cloned board" do
      source_root = Boards::RobustSets.find_root("core-60")
      cloned_root = described_class.new(source_root, communicator: communicator).call

      expect(cloned_root.settings["disable_scroll"]).to be(true)
      fringe = owner.boards.where("COALESCE((settings->>'builder_child')::boolean, false)")
      expect(fringe.count).to be > 0
      fringe.each do |board|
        expect(board.settings["disable_scroll"]).to be(true),
          "expected cloned fringe '#{board.name}' to keep disable_scroll"
      end
    end
  end
end
