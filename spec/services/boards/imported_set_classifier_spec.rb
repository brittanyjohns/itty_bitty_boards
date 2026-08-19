require "rails_helper"

RSpec.describe Boards::ImportedSetClassifier do
  let(:user) { create(:user) }

  def board(name, obf_id: "obf-#{name.parameterize}")
    create(:board, user: user, name: name, obf_id: obf_id)
  end

  def link(from, to, data: {})
    create(:board_image, board: from, predictive_board_id: to.id, data: data)
  end

  describe "walking the set from its root" do
    it "pins the root as a main board and demotes every page under it" do
      root = board("Core")
      food = board("Food")
      snacks = board("Snacks")
      link(root, food)
      link(food, snacks)

      described_class.new(root).call

      expect(root.reload.sub_board).to be false
      expect(root.pinned_main_board?).to be true
      expect(food.reload.sub_board).to be true
      expect(snacks.reload.sub_board).to be true
    end

    it "tags demoted pages so the sub-board tag filter agrees with the flag" do
      root = board("Core")
      page = board("Food")
      link(root, page)

      described_class.new(root).call

      expect(page.reload.tags).to include(Board::IS_SUB_BOARD_TAG)
      expect(root.reload.tags || []).not_to include(Board::IS_SUB_BOARD_TAG)
    end

    it "does not follow a back tile out of the set" do
      root = board("Core")
      page = board("Food")
      outsider = board("Someone else's board")
      link(root, page)
      link(page, outsider, data: { "back_tile" => true })

      described_class.new(root).call

      expect(outsider.reload.sub_board).to be false
    end
  end

  describe "with explicit membership" do
    it "demotes every member but the root, including a page nothing links to" do
      root = board("Core")
      linked = board("Food")
      orphan = board("Unreachable")
      link(root, linked)

      described_class.new(root, member_ids: [root.id, linked.id, orphan.id]).call

      expect(root.reload.sub_board).to be false
      expect(linked.reload.sub_board).to be true
      expect(orphan.reload.sub_board).to be true
    end
  end

  it "keeps the root a main board across a later unrelated save" do
    root = board("Core")
    page = board("Food")
    link(root, page)
    # Every page of a set carries a way home, so the root has inbound links.
    link(page, root, data: { "back_tile" => true })

    described_class.new(root).call
    root.reload.update!(description: "renamed the description")

    expect(root.reload.sub_board).to be false
  end

  it "is idempotent and leaves settled boards untouched" do
    root = board("Core")
    page = board("Food")
    link(root, page)
    described_class.new(root).call

    root_touched_at = root.reload.updated_at
    page_touched_at = page.reload.updated_at
    described_class.new(root).call

    expect(root.reload.updated_at).to eq(root_touched_at)
    expect(page.reload.updated_at).to eq(page_touched_at)
  end

  it "reports the pages without writing anything when dry_run" do
    root = board("Core")
    page = board("Food")
    link(root, page)

    expect(described_class.new(root, dry_run: true).call).to eq([page.id])
    expect(page.reload.sub_board).to be_falsey
    expect(root.reload.pinned_main_board?).to be false
  end

  it "no-ops without a root board" do
    expect(described_class.new(nil).call).to eq([])
  end
end
