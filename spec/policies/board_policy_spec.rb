require "rails_helper"

RSpec.describe BoardPolicy do
  describe "#update?" do
    context "a free user over their board limit" do
      let(:user) { create(:free_user) }
      let!(:designated) { create(:board, user: user) }
      let!(:other_board) { create(:board, user: user) }

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
end
