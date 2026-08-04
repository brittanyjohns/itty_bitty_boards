require "rails_helper"

RSpec.describe Boards::BoardGroupCreator do
  let(:user) { create(:user) }

  def add_tile(board, label:, links_to: nil)
    image = FactoryBot.create(:image, label: label)
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: links_to&.id)
  end

  describe "when the board has no eligible group yet" do
    it "creates a new group rooted at the board with every reachable board as a member" do
      home = create(:board, user: user, name: "Home")
      food = create(:board, user: user, name: "Food")
      add_tile(home, label: "Food", links_to: food)
      add_tile(food, label: "apple")

      creator = described_class.new(board: home, user: user)
      group = creator.call

      expect(group).to be_persisted
      expect(group.root_board_id).to eq(home.id)
      expect(group.name).to eq("Home")
      expect(group.builder).to be(false)
      expect(group.boards.map(&:id)).to contain_exactly(home.id, food.id)
      expect(creator.created?).to be(true)
    end
  end

  describe "when an admin creates a group for another user's board" do
    it "owns the resulting group by the board's actual owner, not the acting admin" do
      admin = create(:admin_user)
      home = create(:board, user: user, name: "Home")

      group = described_class.new(board: home, user: admin).call

      expect(group.user_id).to eq(user.id)
      expect(group.user_id).not_to eq(admin.id)
    end

    it "checks the board owner's limit, not the acting admin's" do
      admin = create(:admin_user)
      home = create(:board, user: user, name: "Home")
      user.update!(settings: (user.settings || {}).merge("board_group_limit" => 0))

      expect {
        described_class.new(board: home, user: admin).call
      }.to raise_error(Boards::BoardGroupCreator::LimitReached)
    end
  end

  describe "when the board already has an eligible group" do
    it "returns the existing group instead of creating a duplicate" do
      home = create(:board, user: user, name: "Home")
      existing = create(:board_group, user: user, builder: true)
      existing.add_board(home)

      expect {
        result = described_class.new(board: home, user: user).call
        expect(result).to eq(existing)
      }.not_to change(BoardGroup, :count)
    end

    it "reports created? as false when reusing an existing group" do
      home = create(:board, user: user, name: "Home")
      existing = create(:board_group, user: user, builder: true)
      existing.add_board(home)

      creator = described_class.new(board: home, user: user)
      creator.call

      expect(creator.created?).to be(false)
    end

    it "re-syncs membership with newly-reachable boards without duplicating the group" do
      home = create(:board, user: user, name: "Home")
      existing = create(:board_group, user: user, builder: true)
      existing.add_board(home)

      food = create(:board, user: user, name: "Food")
      add_tile(home, label: "Food", links_to: food)

      expect {
        result = described_class.new(board: home, user: user).call
        expect(result).to eq(existing)
        expect(result.boards.map(&:id)).to contain_exactly(home.id, food.id)
      }.not_to change(BoardGroup, :count)
    end

    it "never removes an existing member that's no longer reachable" do
      home = create(:board, user: user, name: "Home")
      manually_kept = create(:board, user: user, name: "Manually Kept")
      existing = create(:board_group, user: user, builder: true)
      existing.add_board(home)
      existing.add_board(manually_kept)

      described_class.new(board: home, user: user).call

      expect(existing.reload.boards.map(&:id)).to include(manually_kept.id)
    end
  end

  describe "when the user is at their board-group limit" do
    before { user.update!(settings: (user.settings || {}).merge("board_group_limit" => 0)) }

    it "raises LimitReached and creates nothing" do
      home = create(:board, user: user, name: "Home")

      expect {
        described_class.new(board: home, user: user).call
      }.to raise_error(Boards::BoardGroupCreator::LimitReached)
      expect(BoardGroup.count).to eq(0)
    end

    it "still returns the existing group without raising, even at the limit" do
      home = create(:board, user: user, name: "Home")
      existing = create(:board_group, user: user, builder: true)
      existing.add_board(home)

      expect { described_class.new(board: home, user: user).call }.not_to raise_error
    end
  end
end
