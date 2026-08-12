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

  # The reported bug, modelled on the imported "with-a-medic" set: deleting a
  # child PAGE walked up its Go back tile into the set root and then back down
  # across every sibling, and offered to delete the root.
  describe "a page inside an imported board set" do
    let!(:medic)  { create(:board, user: user, name: "With a Medic") }
    let!(:hurts)  { create(:board, user: user, name: "Where it hurts") }
    let!(:feel)   { create(:board, user: user, name: "How I feel") }
    let!(:spell)  { create(:board, user: user, name: "Spell a word") }
    let!(:qwerty) { create(:board, user: user, name: "QWERTY Keyboard") }

    # An OBZ import writes a back button as a plain folder tile with no flags,
    # so the go-back tiles here are deliberately unmarked.
    let!(:go_back) { link(spell, medic) }

    let!(:group) do
      group = create(:board_group, user: user)
      [medic, hurts, feel, spell].each { |b| group.board_group_boards.create!(board: b) }
      group.update!(root_board_id: medic.id)
      group
    end

    before do
      link(medic, hurts)
      link(medic, feel)
      link(hurts, medic)
      link(feel, medic)
      link(spell, qwerty)
    end

    it "does not offer the set root or its siblings as subboards of the page" do
      tree = described_class.new(spell)

      expect(tree.deletable_ids).not_to include(medic.id, hurts.id, feel.id)
      expect(tree.kept.map { |k| k[:id] }).not_to include(medic.id)
    end

    it "still cascades a page the board genuinely owns" do
      tree = described_class.new(spell)

      expect(tree.deletable_ids).to eq([qwerty.id])
      expect(tree.summary).to include(total: 1, deletable_count: 1, kept_count: 0)
    end

    it "excludes the root even when the go-back tile is flagged" do
      go_back.update!(data: { "back_tile" => true })

      expect(described_class.new(spell).deletable_ids).to eq([qwerty.id])
    end

    it "keeps a page that is also reached from elsewhere in the set" do
      link(hurts, qwerty)

      tree = described_class.new(spell)
      expect(tree.deletable_ids).to be_empty
      expect(tree.kept).to eq([{ id: qwerty.id, name: "QWERTY Keyboard", reason: :referenced_outside }])
    end

    it "leaves the root's own cascade alone" do
      tree = described_class.new(medic)

      expect(tree.deletable_ids).to match_array([hurts.id, feel.id])
    end

    it "falls back to today's behaviour when the set has no root board" do
      group.update!(root_board_id: nil)

      expect(described_class.new(spell).deletable_ids).to include(medic.id)
    end

    it "protects the root of every set the board belongs to" do
      other_root = create(:board, user: user, name: "Another home")
      link(spell, other_root)
      other = create(:board_group, user: user)
      [other_root, spell].each { |b| other.board_group_boards.create!(board: b) }
      other.update!(root_board_id: other_root.id)

      expect(described_class.new(spell).deletable_ids).to eq([qwerty.id])
    end

    it "offers no cascade at all when the walk is truncated" do
      stub_const("Boards::ReachableBoardIds::MAX_BOARDS", 1)

      tree = described_class.new(spell)
      expect(tree.any?).to be false
      expect(tree.summary).to be_nil
    end
  end

  describe "a page whose back tile is flagged but belongs to no set" do
    let!(:page) { create(:board, user: user, name: "Food") }

    it "does not walk up through the flagged tile" do
      create(:board_image, board: page, predictive_board_id: root.id,
                           data: { "back_tile" => true })

      expect(described_class.new(page).any?).to be false
    end
  end
end
