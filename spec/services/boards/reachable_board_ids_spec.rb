require "rails_helper"

RSpec.describe Boards::ReachableBoardIds do
  let(:user) { create(:user) }

  def board(name)
    create(:board, user: user, name: name)
  end

  def link(from, to, data: {})
    create(:board_image, board: from, predictive_board_id: to.id, data: data)
  end

  it "returns the seeds even when nothing links out" do
    root = board("Home")

    expect(described_class.new([root.id]).ids).to eq([root.id])
  end

  it "walks folder links breadth-first" do
    root = board("Home")
    page = board("Food")
    deep = board("Snacks")
    link(root, page)
    link(page, deep)

    expect(described_class.new([root.id]).ids).to eq([root.id, page.id, deep.id])
  end

  it "ignores a tile pointing back at its own board" do
    root = board("Home")
    create(:board_image, board: root, predictive_board_id: root.id)

    expect(described_class.new([root.id]).ids).to eq([root.id])
  end

  it "terminates on a link cycle" do
    root = board("Home")
    page = board("Food")
    link(root, page)
    link(page, root)

    expect(described_class.new([root.id]).ids).to contain_exactly(root.id, page.id)
  end

  it "never enters an excluded board" do
    root = board("Home")
    page = board("Food")
    link(root, page)

    expect(described_class.new([root.id], exclude_ids: [page.id]).ids).to eq([root.id])
  end

  # Excluding has to stop the walk, not just filter the result — otherwise the
  # excluded board's own links still drag its neighbours in.
  it "does not expand through an excluded board" do
    root = board("Home")
    page = board("Food")
    beyond = board("Snacks")
    link(root, page)
    link(page, beyond)

    ids = described_class.new([root.id], exclude_ids: [page.id]).ids

    expect(ids).to eq([root.id])
  end

  it "stops at a back tile when asked to" do
    page = board("Food")
    root = board("Home")
    link(page, root, data: { "back_tile" => true })

    expect(described_class.new([page.id], skip_back_tiles: true).ids).to eq([page.id])
    expect(described_class.new([page.id], skip_back_tiles: false).ids).to eq([page.id, root.id])
  end

  it "treats a nav tile as a back tile" do
    page = board("Food")
    root = board("Home")
    link(page, root, data: { Boards::NavRowSync::NAV_TILE_KEY => true })

    expect(described_class.new([page.id], skip_back_tiles: true).ids).to eq([page.id])
  end

  it "reports truncation when the walk hits the cap" do
    root = board("Home")
    a = board("A")
    b = board("B")
    link(root, a)
    link(a, b)

    walk = described_class.new([root.id], limit: 2)

    expect(walk.truncated?).to be(true)
  end

  it "is not truncated when the walk finishes inside the cap" do
    root = board("Home")
    page = board("Food")
    link(root, page)

    walk = described_class.new([root.id], limit: 50)

    expect(walk.ids).to contain_exactly(root.id, page.id)
    expect(walk.truncated?).to be(false)
  end
end
