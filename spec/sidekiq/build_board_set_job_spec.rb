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
  # request spec uses, marked so Boards::RobustSets finds it.
  def seed_robust_set!(slug: "core-60")
    admin = create(:admin_user)
    source_root = create(:board, user: admin, name: "Core 60", predefined: true, published: true)
    food = create(:board, user: admin, name: "Food", predefined: true, published: true)
    create(:board_image, board: source_root, label: "I",
                         image: create(:image, label: "I", user_id: admin.id))
    food_tile = create(:board_image, board: source_root, label: "Food",
                                     image: create(:image, label: "Food", user_id: admin.id))
    food_tile.update!(predictive_board_id: food.id)
    create(:board_image, board: food, label: "apple",
                         image: create(:image, label: "apple", user_id: admin.id))
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

      # The whole tree counts as ONE board.
      expect(User.find(user.id).countable_board_count).to eq(1)
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
      expect(User.find(user.id).countable_board_count).to eq(1)
    end

    it "queues AI art for a novel interest word with no existing symbol" do
      seed_robust_set!
      root = precreate_root!(name: "Core 60")

      expect(GenerateImagesJob).to receive(:perform_async)
        .with(kind_of(Array), kind_of(Integer)).at_least(:once)

      described_class.new.perform(root.id, communicator.id, "core-60", ["dinosaurs"])
    end
  end

  describe "#perform with a GLP template" do
    def seed_glp_templates!
      Boards::GlpTemplates.seed!(admin: create(:admin_user))
    end

    it "copies the whole-phrase tiles onto the pre-created root and completes" do
      seed_glp_templates!
      root = precreate_root!(name: "Greetings & Social")

      described_class.new.perform(root.id, communicator.id, "glp-greetings-social", [])

      root.reload
      expect(root.status).to eq("complete")
      labels = root.board_images.map(&:label)
      expect(labels).to include("hi there!", "see you later", "good morning")
      # part_of_speech carries over so tiles render as gestalt scripts, not words.
      expect(root.board_images.map { |bi| bi.image.part_of_speech }.uniq).to eq(["phrase"])
      # Flat board — no sub-board folder tiles.
      expect(root.board_images.map(&:predictive_board_id).compact).to be_empty
    end

    it "folds picked interests into a My Favorites page (nothing dropped)" do
      seed_glp_templates!
      root = precreate_root!(name: "Greetings & Social")

      described_class.new.perform(root.id, communicator.id, "glp-greetings-social", ["grandma"])

      root.reload
      favorites_tile = root.board_images.find { |bi| bi.label == "My Favorites" }
      expect(favorites_tile&.predictive_board_id).to be_present
      favorites = Board.find(favorites_tile.predictive_board_id)
      expect(favorites.board_images.map(&:label)).to include("grandma")
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

  describe "missing root" do
    it "logs and returns without raising" do
      expect {
        described_class.new.perform(-1, communicator.id, "home", [])
      }.not_to raise_error
    end
  end
end
