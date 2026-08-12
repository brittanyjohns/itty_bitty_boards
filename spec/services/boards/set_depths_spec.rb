require "rails_helper"

RSpec.describe Boards::SetDepths do
  let(:user) { create(:user) }

  def board(name)
    create(:board, user: user, name: name)
  end

  def link(from, to)
    create(:board_image, board: from, predictive_board_id: to.id)
  end

  def group_for(root, *members)
    group = create(:board_group, user: user)
    ([root] + members).each { |b| group.board_group_boards.create!(board: b) }
    group.update!(root_board_id: root.id)
    group
  end

  it "measures folder-tile hops from the root" do
    root = board("Home")
    page = board("Food")
    deep = board("Snacks")
    link(root, page)
    link(page, deep)

    depths = described_class.new(group_for(root, page, deep)).call

    expect(depths).to eq(root.id => 0, page.id => 1, deep.id => 2)
  end

  it "gives a board the shortest depth when two parents reach it" do
    root = board("Home")
    page = board("Food")
    shared = board("Drinks")
    link(root, page)
    link(root, shared)
    link(page, shared)

    depths = described_class.new(group_for(root, page, shared)).call

    expect(depths[shared.id]).to eq(1)
  end

  # This is the "not linked to home" band on the set map — and the case the
  # back-tile stamper has to treat as deeper than everything, not as depth 0.
  it "leaves a board nothing links to out of the result" do
    root = board("Home")
    orphan = board("Spell a word")

    depths = described_class.new(group_for(root, orphan)).call

    expect(depths).not_to have_key(orphan.id)
  end

  it "terminates on a link cycle" do
    root = board("Home")
    page = board("Food")
    link(root, page)
    link(page, root)

    depths = described_class.new(group_for(root, page)).call

    expect(depths).to eq(root.id => 0, page.id => 1)
  end

  it "ignores a link to a board outside the set" do
    root = board("Home")
    outsider = board("Someone else's board")
    link(root, outsider)

    depths = described_class.new(group_for(root)).call

    expect(depths).to eq(root.id => 0)
  end

  it "is empty when the group has no root board" do
    root = board("Home")
    group = group_for(root)
    group.update!(root_board_id: nil)

    expect(described_class.new(group).call).to eq({})
  end
end
