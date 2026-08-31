require "rails_helper"

RSpec.describe Boards::CloneSetPlanner do
  let(:author) { create(:user) }
  let(:user)   { create(:user) }

  let!(:root) { create(:board, user: author, name: "Home") }

  def link!(from_board, to_board, label:)
    tile = create(:board_image, board: from_board, image: create(:image, label: label))
    tile.update!(predictive_board_id: to_board.id)
    tile
  end

  def with_limit(n)
    user.update!(settings: (user.settings || {}).merge("board_limit" => n))
    User.find(user.id)
  end

  def plan_for(limit)
    described_class.new(root, user: with_limit(limit)).call
  end

  # root -> Food -> Snacks, plus a sibling page. Four boards in the set.
  let!(:food)   { create(:board, user: author, name: "Food") }
  let!(:play)   { create(:board, user: author, name: "Play") }
  let!(:snacks) { create(:board, user: author, name: "Snacks") }

  before do
    link!(root, food, label: "Food")
    link!(root, play, label: "Play")
    link!(food, snacks, label: "Snacks")
  end

  describe "sizing the set" do
    it "counts every board reachable through folder tiles" do
      expect(plan_for(50).boards_in_set).to eq(4)
    end

    it "counts a board reachable twice only once, and survives a cycle" do
      link!(snacks, root, label: "Home")

      expect(plan_for(50).boards_in_set).to eq(4)
    end

    it "stops at the depth cap" do
      plan = described_class.new(root, user: with_limit(50), max_depth: 1).call

      expect(plan.boards_in_set).to eq(3) # root + its two direct pages
    end

    it "reports a single board for a set with no folder tiles" do
      bare = create(:board, user: author, name: "Bare")
      create(:board_image, board: bare, image: create(:image, label: "hi"))

      plan = described_class.new(bare, user: with_limit(50)).call

      expect(plan.boards_in_set).to eq(1)
      expect(plan.boards_to_create).to eq(1)
      expect(plan.tiles_to_flatten).to eq(0)
      expect(plan).to be_complete
      expect(plan.limited_by).to be_nil
    end
  end

  describe "the slot budget" do
    it "copies the whole set when it fits" do
      plan = plan_for(50)

      expect(plan.boards_to_create).to eq(4)
      expect(plan.tiles_to_flatten).to eq(0)
      expect(plan.limited_by).to be_nil
      expect(plan).to be_complete
    end

    it "copies what fits and reports the tiles that will be flattened" do
      plan = plan_for(2)

      # Breadth-first, so the pages nearest the root survive: root + Food.
      expect(plan.boards_to_create).to eq(2)
      # Root's Play tile and Food's Snacks tile both point outside the copy.
      expect(plan.tiles_to_flatten).to eq(2)
      expect(plan.limited_by).to eq("board_limit")
      expect(plan).not_to be_complete
    end

    it "measures the budget against boards the user already owns" do
      create_list(:board, 2, user: user)

      expect(plan_for(3).boards_to_create).to eq(1)
      expect(plan_for(3).remaining_slots).to eq(1)
    end

    it "flattens every folder tile when only the root fits" do
      plan = plan_for(1)

      expect(plan.boards_to_create).to eq(1)
      expect(plan.tiles_to_flatten).to eq(2)
      expect(plan.limited_by).to eq("board_limit")
    end
  end

  describe "the hard ceiling" do
    # Independent of the budget: a Pro user has 300 slots, and cloning 300
    # boards in one request is a timeout, not a limit question. It earns no
    # Upgrade button, because paying more would not copy them.
    it "reports set_size, not board_limit, when the ceiling is what truncated" do
      plan = described_class.new(root, user: with_limit(50), max_set: 2).call

      expect(plan.boards_to_create).to eq(2)
      expect(plan.limited_by).to eq("set_size")
      expect(plan.truncated).to be(true)
    end

    it "is not truncated when the set fits the ceiling exactly" do
      plan = described_class.new(root, user: with_limit(50), max_set: 4).call

      expect(plan.truncated).to be(false)
      expect(plan.limited_by).to be_nil
    end
  end

  describe "an admin" do
    let(:user) { create(:user, role: "admin") }

    it "is never limited, and renders a number rather than Infinity" do
      plan = described_class.new(root, user: User.find(user.id)).call

      expect(plan.boards_to_create).to eq(4)
      expect(plan.remaining_slots).to be_a(Integer)
      expect(plan.limited_by).to be_nil
    end
  end

  it "serializes to string keys for the JSON payload" do
    expect(plan_for(50).as_json.keys).to include(
      "boards_in_set", "boards_to_create", "tiles_to_flatten",
      "remaining_slots", "board_limit", "board_count", "limited_by", "truncated"
    )
  end
end
