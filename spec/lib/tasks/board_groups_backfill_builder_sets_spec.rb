# frozen_string_literal: true

require "rails_helper"
require "rake"

# Backfill task for issue #409 — wrap existing Board Builder trees (a
# `builder_root` board + its predictive children) into a real `builder: true`
# BoardGroup so the set counts as one Board Set, mirroring what #407 made new
# builds do.
RSpec.describe "board_groups:backfill_builder_sets rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["board_groups:backfill_builder_sets"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV.to_hash.slice("DRY_RUN", "USER_ID")
    example.run
    ENV["DRY_RUN"] = original["DRY_RUN"]
    ENV["USER_ID"] = original["USER_ID"]
  end

  before do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
  end

  # Build a builder tree exactly like a pre-#407 set: a root marked
  # builder_root, a child board linked via a folder tile's predictive_board_id,
  # and a grandchild one level deeper. No BoardGroup yet.
  def build_builder_tree!(owner, root_name: "My Built Set")
    root = create(:board, user: owner, name: root_name,
                          settings: { "builder_root" => true })
    child = create(:board, user: owner, name: "Food",
                           settings: { "builder_child" => true })
    grandchild = create(:board, user: owner, name: "Fruit",
                                settings: { "builder_child" => true })

    folder = create(:board_image, board: root, image: create(:image, label: "Food", user_id: owner.id))
    folder.update!(predictive_board_id: child.id)

    deep_folder = create(:board_image, board: child, image: create(:image, label: "Fruit", user_id: owner.id))
    deep_folder.update!(predictive_board_id: grandchild.id)

    { root: root, child: child, grandchild: grandchild }
  end

  describe "a fresh builder tree" do
    let(:owner) { create(:user, plan_type: "basic") }
    let!(:tree) { build_builder_tree!(owner) }

    it "creates a builder BoardGroup wrapping the root + all predictive descendants" do
      expect { run_task }.to change { BoardGroup.builder.count }.by(1)

      group = BoardGroup.builder.find_by(root_board_id: tree[:root].id)
      expect(group).to be_present
      expect(group.user_id).to eq(owner.id)
      expect(group.name).to eq(tree[:root].name)
      expect(group.builder).to be(true)
      expect(group.board_ids).to match_array([tree[:root].id, tree[:child].id, tree[:grandchild].id])
    end

    it "makes the whole tree count as ONE board set (zero extra board slots)" do
      run_task
      expect(owner.reload.countable_board_group_count).to eq(1)
      # Every board in the set is now a builder-group member, so it costs no
      # board slots.
      expect(owner.countable_board_count).to eq(0)
    end

    it "previews without writing anything in DRY_RUN=1" do
      ENV["DRY_RUN"] = "1"
      expect { run_task }.not_to change { BoardGroup.count }
      expect(BoardGroupBoard.count).to eq(0)
    end
  end

  describe "idempotency" do
    let(:owner) { create(:user, plan_type: "basic") }
    let!(:tree) { build_builder_tree!(owner) }

    it "re-running creates no duplicate groups or join rows" do
      run_task
      group = BoardGroup.builder.find_by(root_board_id: tree[:root].id)
      bgb_count = group.board_group_boards.count

      expect { run_task }.not_to change { BoardGroup.count }
      expect { run_task }.not_to change { BoardGroupBoard.count }
      expect(group.reload.board_group_boards.count).to eq(bgb_count)
    end

    it "skips roots that already have a builder BoardGroup" do
      run_task
      # A root post-#407 already wrapped — a second run leaves it alone.
      expect { run_task }.not_to change { BoardGroup.builder.count }
    end
  end

  describe "over-limit report" do
    # A Free user (board_group_limit 1) who already has a hand-made set AND a
    # builder set ends up at 2/1 after backfill — kept, but flagged.
    let(:free_user) { create(:user, plan_type: "free") }
    let!(:handmade_set) { create(:board_group, user: free_user, predefined: false) }
    let!(:tree) { build_builder_tree!(free_user) }

    it "reports the user as over board_group_limit and still backfills (kept, not blocked)" do
      expect(free_user.board_group_limit).to eq(1)

      expect { run_task }.to output(/OVER board_group_limit/).to_stdout

      free_user.reload
      expect(free_user.countable_board_group_count).to eq(2)
      expect(free_user.countable_board_group_count).to be > free_user.board_group_limit
      # The builder set was still created — no one loses access to existing sets.
      expect(BoardGroup.builder.find_by(root_board_id: tree[:root].id)).to be_present
    end

    it "does not flag a user who stays within their limit" do
      basic_user = create(:user, plan_type: "basic")
      build_builder_tree!(basic_user, root_name: "Within Limit Set")

      ENV["USER_ID"] = basic_user.id.to_s
      expect { run_task }.to output(/No users left over board_group_limit/).to_stdout
    end
  end

  describe "USER_ID scoping" do
    let(:owner_a) { create(:user, plan_type: "basic") }
    let(:owner_b) { create(:user, plan_type: "basic") }
    let!(:tree_a) { build_builder_tree!(owner_a, root_name: "A Set") }
    let!(:tree_b) { build_builder_tree!(owner_b, root_name: "B Set") }

    it "only backfills the scoped user" do
      ENV["USER_ID"] = owner_a.id.to_s
      run_task

      expect(BoardGroup.builder.find_by(root_board_id: tree_a[:root].id)).to be_present
      expect(BoardGroup.builder.find_by(root_board_id: tree_b[:root].id)).to be_nil
    end
  end
end
