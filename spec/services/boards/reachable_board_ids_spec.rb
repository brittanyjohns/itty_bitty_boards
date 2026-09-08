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

  describe "admit:" do
    it "is unchanged when admit is nil" do
      root = board("Home")
      page = board("Food")
      link(root, page)

      expect(described_class.new([root.id], admit: nil).ids).to eq([root.id, page.id])
    end

    it "never enters a board it refuses" do
      root = board("Home")
      allowed = board("Food")
      refused = board("Someone Else's")
      link(root, allowed)
      link(root, refused)

      walk = described_class.new([root.id], admit: ->(ids) { ids - [refused.id] })

      expect(walk.ids).to contain_exactly(root.id, allowed.id)
    end

    it "never expands THROUGH a board it refuses" do
      root = board("Home")
      refused = board("Someone Else's")
      beyond = board("Beyond")
      link(root, refused)
      link(refused, beyond)

      walk = described_class.new([root.id], admit: ->(ids) { ids - [refused.id] })

      expect(walk.ids).to eq([root.id])
    end

    it "filters the SEEDS too, so an unentitled seed is not a way in" do
      refused = board("Public Library")
      beyond = board("Beyond")
      link(refused, beyond)

      walk = described_class.new([refused.id], admit: ->(ids) { ids - [refused.id] })

      expect(walk.ids).to be_empty
    end

    it "calls admit once per level, never once per board" do
      root = board("Home")
      pages = Array.new(4) { |i| board("Page #{i}") }
      pages.each { |p| link(root, p) }

      calls = []
      described_class.new([root.id], admit: ->(ids) { calls << ids; ids }).ids

      # One call for the seed level, one for the level holding all four pages.
      expect(calls.size).to eq(2)
      expect(calls.last).to match_array(pages.map(&:id))
    end
  end

  describe "max_depth:" do
    it "stops after the given number of levels and reports truncation" do
      root = board("Home")
      page = board("Food")
      deep = board("Snacks")
      link(root, page)
      link(page, deep)

      walk = described_class.new([root.id], max_depth: 1)

      expect(walk.ids).to contain_exactly(root.id, page.id)
      expect(walk.truncated?).to be(true)
    end

    it "is not truncated when the graph is shallower than the cap" do
      root = board("Home")
      page = board("Food")
      link(root, page)

      walk = described_class.new([root.id], max_depth: 5)

      expect(walk.truncated?).to be(false)
    end
  end

  describe "track_origins:" do
    it "is empty unless asked for" do
      root = board("Home")

      expect(described_class.new([root.id]).origins).to be_empty
    end

    it "reports a seed as its own origin" do
      root = board("Home")

      walk = described_class.new([root.id], track_origins: true)

      expect(walk.origins_for(root.id)).to contain_exactly(root.id)
    end

    it "attributes a page to every seed that reaches it" do
      root_a = board("Core A")
      root_b = board("Core B")
      page = board("Food")
      link(root_a, page)
      link(root_b, page)

      walk = described_class.new([root_a.id, root_b.id], track_origins: true)

      expect(walk.origins_for(page.id)).to contain_exactly(root_a.id, root_b.id)
    end

    it "carries origins down a chain" do
      root = board("Home")
      page = board("Food")
      deep = board("Snacks")
      link(root, page)
      link(page, deep)

      walk = described_class.new([root.id], track_origins: true)

      expect(walk.origins_for(deep.id)).to contain_exactly(root.id)
    end

    # BFS alone loses this: `shared` is first reached from root_a at depth 1,
    # so it never re-walks its own links when root_b reaches it at depth 2, and
    # `leaf` would never learn about root_b.
    it "settles a diamond where a second seed arrives at a deeper level" do
      root_a = board("Core A")
      root_b = board("Core B")
      hop = board("Hop")
      shared = board("Shared")
      leaf = board("Leaf")
      link(root_a, shared)
      link(shared, leaf)
      link(root_b, hop)
      link(hop, shared)

      walk = described_class.new([root_a.id, root_b.id], track_origins: true)

      expect(walk.origins_for(leaf.id)).to contain_exactly(root_a.id, root_b.id)
    end
  end
end
