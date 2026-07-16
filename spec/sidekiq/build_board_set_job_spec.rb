require "rails_helper"

RSpec.describe BuildBoardSetJob do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }

  before { allow_any_instance_of(Grover).to receive(:to_png).and_return(ChunkyPNG::Image.new(1, 1).to_blob) }

  # Mirrors what Api::V1::BoardBuilderController#create persists in-request
  # before enqueueing this job: a bare root in "building_board", attached to
  # the communicator as a favorite.
  def precreate_root!(name:, for_communicator: communicator, owner: user)
    root = Board.new(name: name, user: owner)
    root.board_type = "dynamic"
    root.assign_parent
    root.voice = VoiceService.normalize_voice(for_communicator.voice)
    root.generate_unique_slug
    root.settings = (root.settings || {}).merge("builder_root" => true)
    root.status = "building_board"
    root.save!
    child_board = for_communicator.child_boards.create!(board: root, created_by_id: owner.id)
    child_board.update!(favorite: true)
    root
  end

  # Seeds a tiny admin-owned robust set (root + Food fringe), same shape the
  # request spec uses, marked so Boards::RobustSets finds it. The Food page
  # carries its own "Food" SELF tile linking back to the root, mirroring the
  # authored templates (see db/seeds/board_builder_sets/README.md).
  def seed_robust_set!(slug: "core-60")
    admin = create(:admin_user)
    source_root = create(:board, user: admin, name: "Core 60", predefined: true, published: true)
    food = create(:board, user: admin, name: "Food", predefined: true, published: true)
    create(:board_image, board: source_root, label: "I",
                         image: create(:image, label: "I", user_id: admin.id))
    food_image = create(:image, label: "Food", user_id: admin.id)
    food_tile = create(:board_image, board: source_root, label: "Food", image: food_image)
    food_tile.update!(predictive_board_id: food.id)
    create(:board_image, board: food, label: "apple",
                         image: create(:image, label: "apple", user_id: admin.id))
    self_tile = create(:board_image, board: food, label: "Food", image: food_image)
    self_tile.update!(predictive_board_id: source_root.id)
    Boards::RobustSets.mark_root!(source_root, slug)
    source_root
  end

  describe "#perform with a starter template" do
    it "builds the full tree under the pre-created root and marks it complete" do
      root = precreate_root!(name: "Home")

      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs", "grandma"])

      root.reload
      expect(root.status).to eq("complete")
      expect(root.settings["builder_root"]).to be(true)

      # Core tiles landed on the SAME root the controller returned.
      labels = root.board_images.map(&:label)
      expect(labels).to include("I", "want", "Food", "Feelings", "Play")

      # Folder tiles link to builder_child sub-boards.
      play_tile = root.board_images.find { |bi| bi.label == "Play" }
      expect(play_tile.predictive_board_id).to be_present
      play_board = Board.find(play_tile.predictive_board_id)
      expect(play_board.settings["builder_child"]).to be(true)
      expect(play_board.board_images.map(&:label)).to include("dinosaurs", "ball")

      # Unmatched interest fell through to "My Favorites".
      favorites_tile = root.board_images.find { |bi| bi.label == "My Favorites" }
      favorites_board = Board.find(favorites_tile.predictive_board_id)
      expect(favorites_board.board_images.map(&:label)).to contain_exactly("grandma")

      # Only the root carries a generation status.
      children = user.boards.where("COALESCE((settings->>'builder_child')::boolean, false)")
      expect(children).to be_present
      expect(children.pluck(:status)).not_to include("building_board", "complete", "failed")

      # No second ChildBoard — the controller's in-request attach is the only one.
      expect(communicator.child_boards.where(board_id: root.id).count).to eq(1)
      expect(communicator.child_boards.count).to eq(1)

      # Builder markers persist as transition metadata; the "counts as one"
      # property now lives in the builder BoardGroup (see the #407 attachment
      # specs) — this job invocation passes no group, so it asserts the markers.
      expect(children.pluck("settings").map { |s| s["builder_child"] }).to all(be(true))
    end

    it "preserves the root identity the 201 payload exposed (name, slug, user)" do
      root = precreate_root!(name: "Home")
      original_slug = root.slug

      described_class.new.perform(root.id, communicator.id, "home", [])

      root.reload
      expect(root.name).to eq("Home")
      expect(root.slug).to eq(original_slug)
      expect(root.user_id).to eq(user.id)
    end
  end

  describe "#perform sub-board previews from folder tiles" do
    it "uses the linking folder tile's image as each sub-board's thumbnail instead of a generated preview" do
      root = precreate_root!(name: "Home")

      # Give the home template's folder labels art-bearing owner images so their
      # folder tiles resolve to a real URL (the resolver prefers art-bearing
      # images), exercising the positive path rather than vacuously skipping.
      ["Food", "Play", "Feelings", "My Favorites"].each do |label|
        img = create(:image, label: label, user_id: user.id, src_url: "https://example.com/#{label.parameterize}.png")
        create(:doc, documentable: img, user: user)
      end

      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs", "grandma"])

      children = user.boards.where("COALESCE((settings->>'builder_child')::boolean, false)").to_a
      expect(children).to be_present

      set_ids = (children.map(&:id) + [root.id])

      matched = 0
      children.each do |child|
        # No PNG preview is rendered for a sub-board.
        expect(child.preview_image).not_to be_attached,
          "expected child ##{child.id} #{child.name.inspect} to have no generated preview"

        tile = BoardImage.where(board_id: set_ids, predictive_board_id: child.id).first
        next unless tile

        expected = tile.tile_image_url(user)
        next if expected.blank?

        expect(child.read_attribute(:display_image_url)).to eq(expected),
          "expected child ##{child.id} #{child.name.inspect} thumbnail to match its folder tile"
        matched += 1
      end

      # The home template's folder tiles resolve to real art, so at least one
      # sub-board thumbnail is sourced from its tile (not vacuously skipped).
      expect(matched).to be > 0
    end
  end

  describe "#perform scope classification" do
    it "registers the root as in_use and a main board, not a sub-board" do
      root = precreate_root!(name: "Home")

      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs"])

      root.reload
      expect(root.in_use).to be(true)
      expect(root.sub_board).to be_falsey
      expect(Board.main_boards).to include(root)
      expect(Board.in_use).to include(root)
      expect(Board.sub_boards).not_to include(root)
    end

    it "marks every child page as a sub-board (kept out of main_boards)" do
      root = precreate_root!(name: "Home")

      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs", "grandma"])

      children = user.boards.where("COALESCE((settings->>'builder_child')::boolean, false)")
      expect(children).to be_present

      children.each do |child|
        expect(child.sub_board).to be(true), "expected child ##{child.id} #{child.name.inspect} to be a sub_board"
      end

      expect(Board.main_boards).not_to include(*children)
      expect(Board.sub_boards).to include(*children)
    end

    it "leaves every child page unfrozen so it behaves like any other board" do
      root = precreate_root!(name: "Home")

      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs", "grandma"])

      children = user.boards.where("COALESCE((settings->>'builder_child')::boolean, false)")
      expect(children).to be_present

      children.each do |child|
        expect(child.is_frozen?).to be(false), "expected child ##{child.id} #{child.name.inspect} to be unfrozen"
      end
    end

    it "reports the children as unfrozen on the api_view" do
      root = precreate_root!(name: "Home")
      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs"])

      child = user.boards.where("COALESCE((settings->>'builder_child')::boolean, false)").first
      expect(child.user_api_view[:frozen]).to be(false)
    end
  end

  # A page's SELF tile (the "Food" tile on the Food page, which links home) is
  # the one folder tile that speaks — it's the you-are-here anchor. Everything
  # else that opens a board stays muted.
  describe "#perform self-tile muting" do
    it "leaves the self tile unmuted while muting the other folder tiles" do
      seed_robust_set!
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "core-60", [])

      food = user.boards.find_by(name: "Food")
      self_tile = food.board_images.find { |bi| bi.label == "Food" }
      expect(self_tile).to be_present
      expect(self_tile.predictive_board_id).to eq(root.id)
      expect(self_tile.data.to_h["mute_name"]).not_to be(true)

      food_folder = root.board_images.find { |bi| bi.label == "Food" }
      expect(food_folder.data["mute_name"]).to be(true)
    end

    it "keeps word tiles unmuted" do
      seed_robust_set!
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "core-60", [])

      food = user.boards.find_by(name: "Food")
      apple = food.board_images.find { |bi| bi.label == "apple" }
      expect(apple.data.to_h["mute_name"]).not_to be(true)
    end
  end

  describe "#perform with a robust seeded set" do
    it "clones the set into the pre-created root, rewires links, routes interests, and completes" do
      source_root = seed_robust_set!
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "core-60", ["pizza"])

      root.reload
      expect(root.status).to eq("complete")
      expect(root.board_images.map(&:label)).to include("I", "Food")

      cloned_food = user.boards.find_by(name: "Food")
      expect(cloned_food).to be_present
      expect(cloned_food.settings["builder_child"]).to be(true)
      expect(cloned_food.board_images.map(&:label)).to include("apple", "pizza")

      # Folder tile points at the CLONED fringe, not the admin source.
      food_tile = root.board_images.find { |bi| bi.label == "Food" }
      expect(food_tile.predictive_board_id).to eq(cloned_food.id)

      # Source set untouched; user's copy never surfaces as a pickable template.
      expect(source_root.reload.user_id).not_to eq(user.id)
      expect(Boards::RobustSets.all_roots.pluck(:id)).to contain_exactly(source_root.id)

      expect(communicator.child_boards.count).to eq(1)
      # Builder markers persist; "counts as one" lives in the group (#407).
      expect(cloned_food.reload.settings["builder_child"]).to be(true)
    end

    it "queues AI art for a novel interest word with no existing symbol" do
      seed_robust_set!
      root = precreate_root!(name: "Core 60")

      expect(GenerateImagesJob).to receive(:perform_async)
        .with(kind_of(Array), kind_of(Integer)).at_least(:once)

      described_class.new.perform(root.id, communicator.id, "core-60", ["dinosaurs"])
    end
  end

  describe "#perform Phrases layer (gestalt integration)" do
    def seed_glp_templates!
      Boards::GlpTemplates.seed!(admin: create(:admin_user))
    end

    before do
      seed_robust_set!
      seed_glp_templates!
    end

    it "links an integrated Phrases page with the six function sub-pages" do
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "standard", [])

      root.reload
      expect(root.status).to eq("complete")

      phrases_tile = root.board_images.find { |bi| bi.label == "Phrases" }
      expect(phrases_tile&.predictive_board_id).to be_present

      phrases_board = Board.find(phrases_tile.predictive_board_id)
      function_tiles = phrases_board.board_images.select { |bi| bi.predictive_board_id.present? }
      expect(function_tiles.size).to eq(6)

      greetings = Board.find(function_tiles.find { |bi| bi.label == "Greetings & Social" }.predictive_board_id)
      expect(greetings.board_images.map(&:label)).to include("hi there!", "good morning")
      expect(greetings.board_images.map { |bi| bi.image.part_of_speech }.uniq).to eq(["phrase"])
    end

    it "wires the new Phrases board as the communicator's and owner's phrase board" do
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "standard", [])

      phrases_tile = root.reload.board_images.find { |bi| bi.label == "Phrases" }
      phrases_board_id = phrases_tile.predictive_board_id

      expect(communicator.reload.settings["phrase_board_id"]).to eq(phrases_board_id)
      expect(user.reload.settings["phrase_board_id"]).to eq(phrases_board_id)
    end

    it "never clobbers a phrase board the user already picked" do
      communicator.update!(settings: (communicator.settings || {}).merge("phrase_board_id" => 4242))
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "standard", [])

      expect(communicator.reload.settings["phrase_board_id"]).to eq(4242)
    end

    it "surfaces a quick-phrase strip on the home board for an early-stage processor" do
      communicator.update!(details: (communicator.details || {}).merge("glp_stage" => 1))
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "standard", [])

      root.reload
      phrase_tiles = root.board_images.select { |bi| bi.image.part_of_speech == "phrase" }
      expect(phrase_tiles).not_to be_empty
    end
  end

  describe "#perform with a complexity level (hybrid path)" do
    before { seed_robust_set! }

    it "routes through StructurePlanner and completes" do
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "standard", ["pizza"])

      root.reload
      expect(root.status).to eq("complete")
      expect(root.board_images.map(&:label)).to include("I", "Food")

      cloned_food = user.boards.find_by(name: "Food")
      expect(cloned_food).to be_present
      expect(cloned_food.board_images.map(&:label)).to include("apple", "pizza")
    end

    it "clones the authored core set intact (no dead folder tiles) and completes" do
      root = precreate_root!(name: "Core 60")

      described_class.new.perform(root.id, communicator.id, "starter", [])

      root.reload
      expect(root.status).to eq("complete")
      # The authored set is cloned intact — every folder tile on the root links
      # to a real board. None are left dead (excluding authored seed pages used
      # to strip the sub-board while leaving its tile behind).
      dead = root.board_images.select do |bi|
        label = bi.label.to_s
        label.length > 2 && label[0] == label[0].upcase && bi.predictive_board_id.nil?
      end
      expect(dead).to be_empty
    end

    it "falls back AI-generated pages to My Favorites when user has no credits" do
      root = precreate_root!(name: "Core 60")
      # User starts with free-tier credits (5) from after_create, but we zero it
      user.update_columns(plan_credits_balance: 0, topup_credits_balance: 0)

      # "xylophone_crafting" won't match any seed set or prebuilt fringe template
      described_class.new.perform(root.id, communicator.id, "standard", ["xylophone_crafting"])

      root.reload
      expect(root.status).to eq("complete")
    end

    # "backpack" -> School, which is not a seed page or prebuilt template in
    # core-60, so it used to spawn a whole AI-generated board named after the one
    # word. It should not: no AI call, and the word lands in My Favorites.
    it "does not spawn a dedicated AI board for a lone niche interest" do
      root = precreate_root!(name: "Core 60")

      expect(Boards::AiPageGenerator).not_to receive(:new)
      described_class.new.perform(root.id, communicator.id, "standard", ["backpack"])

      root.reload
      expect(root.status).to eq("complete")

      folder_names = root.board_images.select(&:is_dynamic?).map do |bi|
        Board.find(bi.predictive_board_id).name.to_s.downcase
      end
      expect(folder_names).not_to include("backpack")

      favorites = user.boards.find_by(name: "My Favorites")
      expect(favorites).to be_present
      expect(favorites.board_images.map { |bi| bi.label.to_s.downcase }).to include("backpack")
    end

    it "normalizes legacy template keys — core-60 routes to standard path" do
      root = precreate_root!(name: "Core 60")

      # core-60 is not in LEVELS but the job's legacy path handles it;
      # the controller's resolve_build_key resolves "core-60" as template, not level.
      # Verify the job handles this gracefully.
      described_class.new.perform(root.id, communicator.id, "core-60", ["pizza"])

      root.reload
      expect(root.status).to eq("complete")
    end
  end

  describe "preview generation" do
    it "generates a preview synchronously before marking the root complete (starter)" do
      root = precreate_root!(name: "Home")

      expect_any_instance_of(Board).to receive(:generate_previews).once.and_call_original

      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs"])

      root.reload
      expect(root.status).to eq("complete")
      expect(root.preview_image).to be_attached
    end

    it "generates a preview synchronously before marking the root complete (robust set)" do
      seed_robust_set!
      root = precreate_root!(name: "Core 60")

      expect_any_instance_of(Board).to receive(:generate_previews).once.and_call_original

      described_class.new.perform(root.id, communicator.id, "core-60", ["pizza"])

      root.reload
      expect(root.status).to eq("complete")
      expect(root.preview_image).to be_attached
    end
  end

  describe "failure path" do
    it "marks the root failed, re-raises, and leaves no orphan children" do
      root = precreate_root!(name: "Home")
      allow_any_instance_of(Boards::BoardTreeBuilder)
        .to receive(:call).and_raise(Boards::BoardTreeBuilder::BuildError, "boom")

      boards_before = Board.count
      expect {
        described_class.new.perform(root.id, communicator.id, "home", [])
      }.to raise_error(Boards::BoardTreeBuilder::BuildError)

      expect(root.reload.status).to eq("failed")
      # The transactional build rolled back: root remains, nothing else.
      expect(Board.count).to eq(boards_before)
      expect(user.boards.where("COALESCE((settings->>'builder_child')::boolean, false)").count).to eq(0)
      expect(communicator.child_boards.count).to eq(1) # still just the root attach
    end

    it "marks the root failed when a mid-build raise happens inside the tree build (real rollback)" do
      root = precreate_root!(name: "Home")
      # Blow up while linking a folder tile — boards/tiles created up to that
      # point must roll back, leaving only the bare root.
      allow_any_instance_of(BoardImage).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      expect {
        described_class.new.perform(root.id, communicator.id, "home", [])
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(root.reload.status).to eq("failed")
      expect(root.board_images.count).to eq(0)
      expect(user.boards.where("COALESCE((settings->>'builder_child')::boolean, false)").count).to eq(0)
    end

    it "marks the root failed when the communicator is gone" do
      root = precreate_root!(name: "Home")
      missing_id = communicator.id
      communicator.child_boards.destroy_all
      communicator.destroy!

      described_class.new.perform(root.id, missing_id, "home", [])

      expect(root.reload.status).to eq("failed")
    end

    it "marks the root failed on an unknown template (validated again job-side)" do
      root = precreate_root!(name: "Home")

      expect {
        described_class.new.perform(root.id, communicator.id, "nope", [])
      }.to raise_error(Boards::BlueprintAssembler::UnknownTemplate)

      expect(root.reload.status).to eq("failed")
    end
  end

  describe "retry idempotency" do
    it "does not double-build a root that already completed" do
      root = precreate_root!(name: "Home")
      described_class.new.perform(root.id, communicator.id, "home", [])
      tiles_after_first = root.reload.board_images.count
      boards_after_first = Board.count

      described_class.new.perform(root.id, communicator.id, "home", [])

      expect(root.reload.board_images.count).to eq(tiles_after_first)
      expect(Board.count).to eq(boards_after_first)
      expect(root.status).to eq("complete")
    end

    it "treats a root that already has tiles as built (commit landed, status update didn't)" do
      root = precreate_root!(name: "Home")
      described_class.new.perform(root.id, communicator.id, "home", [])
      # Simulate dying between the build transaction's commit and the status flip.
      root.update_column(:status, "building_board")
      boards_before = Board.count

      described_class.new.perform(root.id, communicator.id, "home", [])

      expect(Board.count).to eq(boards_before)
      expect(root.reload.status).to eq("complete")
    end
  end

  # Issue #407: the builder set's boards (root + everything the job builds)
  # become members of a `builder: true` BoardGroup so the set counts as one
  # Board Set (0 board slots) and cascade-deletes as a unit.
  describe "board group attachment (#407)" do
    # Mirrors the controller: pre-create the root, its builder group, add the
    # root at position 0, and hand the group id to the job via options.
    def precreate_root_and_group!(name:)
      root  = precreate_root!(name: name)
      group = user.board_groups.create!(name: name, builder: true)
      group.board_group_boards.create!(board: root, position: 0)
      group.update!(root_board_id: root.id)
      [root, group]
    end

    it "attaches every built board (root + children) to the builder group" do
      root, group = precreate_root_and_group!(name: "Home")

      described_class.new.perform(root.id, communicator.id, "home", ["dinosaurs", "grandma"],
                                  {}, { "board_group_id" => group.id })

      group.reload
      member_ids = group.boards.pluck(:id)
      built_ids  = user.boards.where(predefined: false).pluck(:id)
      # Root + every sub-board the build produced are all group members.
      expect(member_ids).to match_array(built_ids)
      expect(member_ids).to include(root.id)
      expect(built_ids.size).to be > 1

      # The whole set costs zero board slots and one board-set slot.
      fresh = User.find(user.id)
      expect(fresh.countable_board_count).to eq(0)
      expect(fresh.countable_board_group_count).to eq(1)
    end

    it "is idempotent — a retry does not duplicate board_group_boards rows" do
      root, group = precreate_root_and_group!(name: "Home")
      described_class.new.perform(root.id, communicator.id, "home", [], {}, { "board_group_id" => group.id })
      members_after_first = group.reload.board_group_boards.count

      described_class.new.perform(root.id, communicator.id, "home", [], {}, { "board_group_id" => group.id })

      expect(group.reload.board_group_boards.count).to eq(members_after_first)
    end

    it "backfills membership when an already-built set is re-run with the group id" do
      root, group = precreate_root_and_group!(name: "Home")
      # Build with NO group id (simulates a set built before the attach existed).
      described_class.new.perform(root.id, communicator.id, "home", [])
      expect(group.reload.board_group_boards.count).to eq(1) # only the controller's root

      # Re-run (root is complete) WITH the group id — the early-return path still
      # attaches the rest.
      described_class.new.perform(root.id, communicator.id, "home", [], {}, { "board_group_id" => group.id })

      expect(group.reload.boards.pluck(:id)).to match_array(user.boards.where(predefined: false).pluck(:id))
    end
  end

  describe "missing root" do
    it "logs and returns without raising" do
      expect {
        described_class.new.perform(-1, communicator.id, "home", [])
      }.not_to raise_error
    end
  end

  # A nil communicator_id is the UNATTACHED path (built for the user alone);
  # a present-but-unresolvable one is a real dangling reference.
  describe "without a communicator" do
    def precreate_unattached_root!(name:, owner: user)
      root = Board.new(name: name, user: owner)
      root.board_type = "dynamic"
      root.assign_parent
      root.voice = VoiceService.normalize_voice(owner.voice)
      root.generate_unique_slug
      root.settings = (root.settings || {}).merge("builder_root" => true)
      root.status = "building_board"
      root.save!
      root
    end

    it "builds the whole tree and completes, creating no ChildBoard" do
      root = precreate_unattached_root!(name: "Home")

      expect {
        described_class.new.perform(root.id, nil, "home", ["dinosaurs"])
      }.not_to change { ChildBoard.count }

      root.reload
      expect(root.status).to eq("complete")
      expect(root.board_images.count).to be > 0

      play_tile = root.board_images.find { |bi| bi.label == "Play" }
      play_board = Board.find(play_tile.predictive_board_id)
      expect(play_board.board_images.map(&:label)).to include("dinosaurs")
    end

    it "builds a robust seeded set unattached" do
      seed_robust_set!
      root = precreate_unattached_root!(name: "Core 60")

      described_class.new.perform(root.id, nil, "core-60", [])

      root.reload
      expect(root.status).to eq("complete")
      expect(root.board_images.map(&:label)).to include("I", "Food")
      expect(ChildBoard.count).to eq(0)
    end

    it "uses the owner's voice for boards it creates" do
      user.update!(settings: { "voice" => { "name" => "openai:nova" } })
      root = precreate_unattached_root!(name: "Home")

      described_class.new.perform(root.id, nil, "home", ["grandma"])

      favorites = Board.find_by(name: "My Favorites", user_id: user.id)
      expect(favorites.voice).to eq("openai:nova")
    end

    it "still fails the root when a communicator_id is given but missing" do
      root = precreate_unattached_root!(name: "Home")

      described_class.new.perform(root.id, -1, "home", [])

      expect(root.reload.status).to eq("failed")
    end
  end

  # Part 2: a leftover interest goes onto an existing matching board where one
  # exists in the set, and only falls through to My Favorites when none does.
  describe "#route_catch_all_to_existing_boards!" do
    let(:job) { described_class.new }

    def link_board!(root, target, label)
      root.board_images.create!(
        image: create(:image, label: label, user_id: root.user_id),
        predictive_board_id: target.id,
      )
    end

    it "drops a leftover word onto the existing board for its category" do
      root = create(:board, user: user, name: "Root")
      food = create(:board, user: user, name: "Food")
      link_board!(root, food, "Food")

      leftover = job.send(:route_catch_all_to_existing_boards!, root, user, ["pizza"], {})

      expect(leftover).to eq([])
      expect(food.reload.board_images.map { |bi| bi.label.to_s.downcase }).to include("pizza")
    end

    it "honors a seed-page alias (Health & Body -> Body)" do
      root = create(:board, user: user, name: "Root")
      body = create(:board, user: user, name: "Body")
      link_board!(root, body, "Body")

      leftover = job.send(:route_catch_all_to_existing_boards!, root, user, ["wibble"],
                          { "wibble" => "Health & Body" })

      expect(leftover).to eq([])
      expect(body.reload.board_images.map { |bi| bi.label.to_s.downcase }).to include("wibble")
    end

    it "returns words with no matching board for the My Favorites fallback" do
      root = create(:board, user: user, name: "Root")
      link_board!(root, create(:board, user: user, name: "Food"), "Food")

      # backpack -> School; no School board in the set
      leftover = job.send(:route_catch_all_to_existing_boards!, root, user, ["backpack"], {})

      expect(leftover).to eq(["backpack"])
    end

    it "never routes into My Favorites (that is the explicit fallback)" do
      root = create(:board, user: user, name: "Root")
      favorites = create(:board, user: user, name: "My Favorites")
      link_board!(root, favorites, "My Favorites")

      leftover = job.send(:route_catch_all_to_existing_boards!, root, user, ["backpack"], {})

      expect(leftover).to eq(["backpack"])
      expect(favorites.reload.board_images.map { |bi| bi.label.to_s.downcase }).not_to include("backpack")
    end
  end
end
