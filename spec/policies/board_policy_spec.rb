require "rails_helper"

RSpec.describe BoardPolicy do
  describe "#update?" do
    context "a free user over their board limit" do
      let(:user) { create(:free_user) }
      let!(:designated) { create(:board, user: user) }
      # Enough boards to cross EDITABLE_BOARD_FLOOR — below it nothing locks,
      # since the floor decouples the editable set from board_limit.
      let!(:filler) do
        Array.new(User::EDITABLE_BOARD_FLOOR) { create(:board, user: user) }
      end
      let!(:other_board) do
        create(:board, user: user).tap { |b| b.update_column(:updated_at, 30.days.ago) }
      end

      it "denies editing a non-designated owned board" do
        user.update!(editable_board_id: designated.id)
        policy = described_class.new(User.find(user.id), other_board)
        expect(policy.update?).to be false
      end

      it "permits editing the designated board" do
        user.update!(editable_board_id: other_board.id)
        policy = described_class.new(User.find(user.id), other_board)
        expect(policy.update?).to be true
      end
    end

    it "permits an admin to edit any board" do
      admin = create(:admin_user)
      board = create(:board, user: create(:user))
      expect(described_class.new(admin, board).update?).to be true
    end

    it "permits a paid user to edit all of their boards" do
      paid = create(:user, plan_type: "pro")
      create(:board, user: paid)
      board = create(:board, user: paid)
      expect(described_class.new(paid, board).update?).to be true
    end
  end

  describe BoardPolicy::Scope do
    it "returns no boards for a nil user rather than raising" do
      create(:board, user: create(:user))

      expect { described_class.new(nil, Board.all).resolve }.not_to raise_error
      expect(described_class.new(nil, Board.all).resolve).to be_empty
    end

    it "returns only the user's own boards" do
      user = create(:user)
      own = create(:board, user: user, board_type: "user")
      create(:board, user: create(:user), board_type: "user")

      expect(described_class.new(user, Board.all).resolve).to contain_exactly(own)
    end
  end
end
