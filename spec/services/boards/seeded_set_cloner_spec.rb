require "rails_helper"

RSpec.describe Boards::SeededSetCloner do
  # Shared source set — built once via before_all. Each example's clones and
  # modifications run inside a savepoint that auto-rolls back.
  before_all do
    # Boards::RobustSets.all_roots is scoped to the SEEDER (DEFAULT_ADMIN_ID +
    # predefined), so the source set has to be owned the way vocab_sets:seed
    # owns it or the catalog lookup can't see it at all.
    @admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
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
    # Category tiles carry a PINNED display_label, the way a curated seeded set
    # really does (the OBF importer pins the authored button label;
    # Boards::BoardTreeBuilder pins the blueprint's folder label). Vocabulary
    # tiles above are left to default, which is what lowercases them.
    food_tile = create(:board_image, board: root, label: "Food", display_label: "Food",
                                     image: create(:image, label: "Food", user_id: admin_user.id))
    food_tile.update!(predictive_board_id: food.id)
    feelings_tile = create(:board_image, board: root, label: "Feelings", display_label: "Feelings",
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

      food_tile = root.board_images.find_by(display_label: "Food")
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

    # The blank->art upgrade above only ever moves a tile from NO picture to a
    # picture. A tile that already carries one keeps it: the copy has to look
    # like the board it was copied from.
    it "keeps a source tile's authored picture instead of re-seeding from the image" do
      @source[:root].board_images.find_by(label: "want")
                    .update_column(:display_image_url, "https://cdn.example.com/want-text.png")
      @source[:root].board_images.reset

      root = described_class.new(@source[:root], communicator: communicator).call

      expect(root.board_images.find_by(label: "want").display_image_url)
        .to eq("https://cdn.example.com/want-text.png")
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

      fav_tile = root.board_images.find_by(display_label: "My Favorites")
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

        food_tile = root.board_images.find_by(display_label: "Food")
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

    # A folder tile pointing at a board that is itself the TOP of a set used to
    # pull that whole board into the clone as an extra PAGE — a second full core
    # board. No nav cell carries its name, so Boards::NavRowSync then minted it
    # a way home labelled with the core set's own name: the stray "Core 84" tile
    # on a page nothing linked to.
    context "when a stray link points at another set's home board" do
      let!(:other_root) do
        create(:board, user: @admin, name: "Core 84", predefined: true, published: true,
                       settings: { Boards::RobustSets::ROOT_MARKER => true,
                                   Boards::RobustSets::SLUG_MARKER => "core-84" })
      end

      before do
        stray = create(:board_image, board: @source[:food], label: "Core 84",
                                     image: create(:image, label: "Core 84", user_id: @admin.id))
        stray.update!(predictive_board_id: other_root.id)
      end

      it "does not clone it into the set as a page" do
        described_class.new(@source[:root], communicator: communicator).call

        expect(owner.boards.pluck(:name)).not_to include("Core 84")
      end

      it "nulls the stray pointer on the clone rather than opening an admin board" do
        described_class.new(@source[:root], communicator: communicator).call

        # `label` is the lowercase matching key (Image#set_label), so match on it
        # case-insensitively rather than on the authored casing.
        stray = owner.boards.find_by(name: "Food").board_images
                     .find { |bi| bi.label.to_s.casecmp?("core 84") }
        expect(stray).to be_present
        expect(stray.predictive_board_id).to be_nil
      end

      it "still excludes it when it is another BUILDER set's root" do
        other_root.update!(settings: { "builder_root" => true })

        described_class.new(@source[:root], communicator: communicator).call

        expect(owner.boards.pluck(:name)).not_to include("Core 84")
      end
    end

    # Both copy paths take the source's layout verbatim, so a seed carrying two
    # tiles on one cell hands every set built from it the same hidden tile — and
    # a full grid that reports a free cell it doesn't have.
    it "does not inherit a stacked cell from the source" do
      tiles = @source[:root].board_images.order(:position).to_a
      first, last = tiles.first, tiles.last
      cell = { "x" => 0, "y" => 0, "w" => 1, "h" => 1 }
      first.update_column(:layout, { "lg" => cell.merge("i" => first.id.to_s) })
      last.update_column(:layout, { "lg" => cell.merge("i" => last.id.to_s) })

      root = described_class.new(@source[:root], communicator: communicator).call

      cells = root.reload.board_images.filter_map { |bi|
        c = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        c && [c["x"].to_i, c["y"].to_i]
      }
      expect(cells.uniq.size).to eq(cells.size)
      expect(root.board_images.count).to eq(tiles.size)
    end

    # Board#clone_with_images dups settings verbatim, so a dup-cloned root
    # arrived still claiming to BE the seed — pickable in the Board Builder
    # catalogue as a template, and resolvable by Boards::RobustSets.find_root.
    it "strips the robust-set catalogue markers from a dup-cloned root" do
      # A dedicated source, not @source[:root]: that one is shared via
      # before_all, and marking it here would leave the markers on the in-memory
      # object after the savepoint rolls the row back — so a later example's
      # `mark_root!` would see no change and write nothing.
      source = create(:board, user: @admin, name: "Core 84 Seed", predefined: true, published: true,
                              settings: { Boards::RobustSets::ROOT_MARKER => true,
                                          Boards::RobustSets::SLUG_MARKER => "core-84" })
      create(:board_image, board: source, label: "I",
                           image: create(:image, label: "I", user_id: @admin.id))

      root = described_class.new(source, communicator: communicator).call

      expect(root.reload.settings).not_to have_key(Boards::RobustSets::ROOT_MARKER)
      expect(root.settings).not_to have_key(Boards::RobustSets::SLUG_MARKER)
      expect(Boards::RobustSets.all_roots.pluck(:id)).not_to include(root.id)
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
        expect(root.board_images.map(&:display_label)).to include("I", "want", "help", "Food", "Feelings")

        cloned_food = owner.boards.find_by(name: "Food")
        food_tile = root.board_images.find_by(display_label: "Food")
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
        expect(root.settings).not_to have_key(Boards::RobustSets::ROOT_MARKER)
        expect(root.settings).not_to have_key(Boards::RobustSets::SLUG_MARKER)
        # Two memberships rather than `contain_exactly`: the source must still
        # be the catalog's root for the slug and the adopted root must never
        # join it, but requiring the catalog to hold NOTHING else couples this
        # example to whatever seeds a neighbouring one leaves behind.
        expect(Boards::RobustSets.all_roots.pluck(:id)).to include(@source[:root].id)
        expect(Boards::RobustSets.all_roots.pluck(:id)).not_to include(root.id)
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
        fav_tile = root.reload.board_images.find_by(display_label: "My Favorites")
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

  # The cloner used to copy the source tile's display_label verbatim, undoing
  # the fold set_labels had just done — so a seed board carrying pre-#636 Title
  # Case propagated it into every set built from it.
  describe "tile casing on clone" do
    # The clone re-resolves art and re-packs positions, so assert on the set of
    # tile text rather than trying to pair a cloned tile back to its source.
    def cloned_root_labels(source_text)
      # Rolled back with the example's savepoint; the shared source set survives.
      @source[:root].board_images.find_by(label: "want")
                    .update_columns(label: source_text.downcase, display_label: source_text)
      # before_all left the association cached on the shared source board.
      @source[:root].reload

      described_class.new(@source[:root], communicator: communicator).call
                     .board_images.pluck(:display_label)
    end

    it "folds a stuck leading capital on a word tile" do
      labels = cloned_root_labels("Higher")

      expect(labels).to include("higher")
      expect(labels).not_to include("Higher")
    end

    it "keeps deliberate casing" do
      expect(cloned_root_labels("iPad")).to include("iPad")
    end

    it "keeps the capital on a curated folder tile" do
      labels = described_class.new(@source[:root], communicator: communicator)
                              .call.board_images.pluck(:display_label)

      expect(labels).to include("Food", "Feelings")
      expect(labels).not_to include("food", "feelings")
    end
  end

  # Regression for #278: seed BOTH real sets, then clone each.
  # A set cloned for a user with no communicator — assignable to one later.
  describe "#call without a communicator" do
    it "clones the whole set for the owner and creates no ChildBoard" do
      root = nil
      expect {
        root = described_class.new(@source[:root], owner: owner).call
      }.not_to change { ChildBoard.count }

      expect(root.user_id).to eq(owner.id)
      expect(root.settings["builder_root"]).to be(true)
      expect(owner.boards.count).to eq(3)

      cloned_food = owner.boards.find_by(name: "Food")
      expect(root.board_images.find_by(display_label: "Food").predictive_board_id).to eq(cloned_food.id)
    end

    it "routes interests into the cloned fringe pages and My Favorites" do
      root = described_class.new(@source[:root], owner: owner,
                                                 interests: ["apple", "grandma"]).call

      cloned_food = owner.boards.find_by(name: "Food")
      expect(cloned_food.board_images.map(&:label)).to include("apple")

      favorites = owner.boards.find_by(name: "My Favorites")
      expect(favorites.board_images.map(&:label)).to contain_exactly("grandma")
      expect(root.board_images.find_by(display_label: "My Favorites")).to be_present
    end

    it "falls back to the owner's voice for boards it creates" do
      owner.update!(settings: { "voice" => { "name" => "openai:nova" } })

      described_class.new(@source[:root], owner: owner, interests: ["grandma"]).call

      expect(owner.boards.find_by(name: "My Favorites").voice).to eq("openai:nova")
    end

    it "raises without an owner or a communicator to derive one from" do
      expect {
        described_class.new(@source[:root]).call
      }.to raise_error(described_class::CloneError, /no owning user/)
    end
  end

  describe "cloning a real seeded robust set" do
    before_all do
      register_openai_webmock_stub!
      register_external_webmock_stubs!
      @seed_admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      VocabSets.seed_slug!("core-60")
      VocabSets.seed_slug!("core-84")
    end

    # Each fringe page's way home is its SELF tile — the "People" tile on the
    # People page (see db/seeds/board_builder_sets/README.md). It must point at
    # the CLONED root, never the admin source it was cloned from.
    %w[core-60 core-84].each do |slug|
      it "gives #{slug} clones a working self tile home from every fringe page" do
        source_root = Boards::RobustSets.find_root(slug)
        cloned_root = described_class.new(source_root, communicator: communicator).call

        fringe = owner.boards.where("COALESCE((settings->>'builder_child')::boolean, false)")
        expect(fringe.count).to be > 0

        fringe.each do |board|
          self_tile = board.board_images.find_by(display_label: board.name)
          expect(self_tile).to be_present, "expected fringe '#{board.name}' to have a '#{board.name}' self tile"
          expect(self_tile.predictive_board_id).to eq(cloned_root.id),
            "expected '#{board.name}' self tile to link home to the cloned root"
        end
      end

      it "leaves no #{slug} fringe page linking at itself" do
        source_root = Boards::RobustSets.find_root(slug)
        described_class.new(source_root, communicator: communicator).call

        owner.boards.where("COALESCE((settings->>'builder_child')::boolean, false)").each do |board|
          selfies = board.board_images.where(predictive_board_id: board.id)
          expect(selfies).to be_empty, "'#{board.name}' has a tile that opens itself"
        end
      end
    end

    it "carries the authored part_of_speech colors onto the cloned set" do
      source_root = Boards::RobustSets.find_root("core-60")
      cloned_root = described_class.new(source_root, communicator: communicator).call

      { "I" => ["pronoun", "#FFEA75"],
        "want" => ["verb", "#A1F571"],
        "what" => ["question", "#A07AFF"] }.each do |label, (pos, hex)|
        tile = cloned_root.board_images.find_by(display_label: label)
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

    # The authored Core 60 grid is 60 tiles in 60 cells, so My Favorites had
    # nowhere to put its folder tile and was skipped outright — the child's own
    # words surfaced nowhere. Boards::FolderPlacer tucks it into "More".
    describe "leftover interests on a full authored grid" do
      let!(:cloned_root) do
        source_root = Boards::RobustSets.find_root("core-60")
        described_class.new(source_root, communicator: communicator, interests: %w[zamboni]).call
      end

      it "surfaces My Favorites in the More drawer without growing the home grid" do
        expect(cloned_root.board_images.count).to eq(60)
        expect(cloned_root.large_screen_rows).to eq(6)
        expect(cloned_root.board_images.map(&:display_label)).not_to include("My Favorites")

        more = Boards::FolderPlacer.drawer_for(cloned_root)
        expect(more).to be_present
        expect(more.board_images.reload.map(&:display_label)).to include("My Favorites")
      end

      it "keeps the leftover word instead of dropping it" do
        favorites = owner.boards.find_by(name: "My Favorites")

        expect(favorites).to be_present
        expect(favorites.board_images.map { |bi| bi.label.to_s.downcase }).to include("zamboni")
      end
    end
  end
end
