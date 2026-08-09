require "rails_helper"

# Boards::SubboardTree answers "if the user checks 'delete the subboards too',
# what actually gets deleted?" — the outbound folder-tile tree from a board,
# split into boards safe to cascade and boards kept because something outside
# the tree still depends on them.
RSpec.describe Boards::SubboardTree do
  let(:user) { create(:user) }
  let(:root) { create(:board, user: user, name: "Home") }

  # A folder tile on `from` that opens `to`.
  def link(from, to)
    create(:board_image, board: from, predictive_board_id: to.id)
  end

  describe "a board with no folder tiles" do
    it "has an empty tree and a nil summary" do
      tree = described_class.new(root)
      expect(tree.any?).to be false
      expect(tree.deletable_ids).to be_empty
      expect(tree.summary).to be_nil
    end

    it "ignores a tile pointing back at the board itself" do
      link(root, root)
      expect(described_class.new(root).any?).to be false
    end
  end

  describe "a nested tree the user owns outright" do
    let!(:child)      { create(:board, user: user, name: "Food") }
    let!(:grandchild) { create(:board, user: user, name: "Snacks") }

    before do
      link(root, child)
      link(child, grandchild)
    end

    it "walks the whole tree, not just direct children" do
      tree = described_class.new(root)
      expect(tree.deletable_ids).to match_array([child.id, grandchild.id])
      expect(tree.kept).to be_empty
      expect(tree.summary).to include(total: 2, deletable_count: 2, kept_count: 0)
      expect(tree.summary[:names]).to match_array(["Food", "Snacks"])
    end

    it "terminates on a link cycle" do
      link(grandchild, root)
      expect(described_class.new(root).deletable_ids).to match_array([child.id, grandchild.id])
    end

    it "does not treat a sibling link inside the tree as an outside reference" do
      link(grandchild, child)
      expect(described_class.new(root).kept).to be_empty
    end
  end

  describe "subboards something else still depends on" do
    let!(:child) { create(:board, user: user, name: "Food") }

    before { link(root, child) }

    it "keeps one referenced by a board outside the tree" do
      outsider = create(:board, user: user, name: "School")
      link(outsider, child)

      tree = described_class.new(root)
      expect(tree.deletable_ids).to be_empty
      expect(tree.kept).to eq([{ id: child.id, name: "Food", reason: :referenced_outside }])
      expect(tree.summary).to include(total: 1, deletable_count: 0, kept_count: 1)
    end

    it "keeps one on a communicator dashboard" do
      create(:child_board, board: child, child_account: create(:child_account, user: user))

      tree = described_class.new(root)
      expect(tree.deletable_ids).to be_empty
      expect(tree.kept.first[:reason]).to eq(:on_communicator)
    end

    it "keeps one shared with a team" do
      TeamBoard.create!(team: create(:team, created_by: user), board: child)

      expect(described_class.new(root).kept.first[:reason]).to eq(:shared_with_team)
    end

    it "keeps one owned by someone else" do
      child.update!(user: create(:user))

      expect(described_class.new(root).kept.first[:reason]).to eq(:not_owned)
    end

    it "keeps a predefined board" do
      child.update!(predefined: true)

      expect(described_class.new(root).kept.first[:reason]).to eq(:predefined)
    end

    it "keeps the kept board but still deletes its safe siblings" do
      create(:child_board, board: child, child_account: create(:child_account, user: user))
      sibling = create(:board, user: user, name: "Play")
      link(root, sibling)

      tree = described_class.new(root)
      expect(tree.deletable_ids).to eq([sibling.id])
      expect(tree.kept.map { |k| k[:id] }).to eq([child.id])
    end
  end
end
