# == Schema Information
#
# Table name: child_boards
#
#  id                :bigint           not null, primary key
#  board_id          :bigint           not null
#  child_account_id  :bigint           not null
#  status            :string
#  settings          :jsonb
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  published         :boolean          default(FALSE)
#  favorite          :boolean          default(FALSE)
#  created_by_id     :bigint
#  original_board_id :bigint
#  layout            :jsonb
#  position          :integer
#
require "rails_helper"

RSpec.describe ChildBoard, type: :model do
  let(:user)         { create(:user) }
  let(:board)        { create(:board, user: user) }
  let(:communicator) { create(:child_account, user: user) }

  describe "uniqueness of (board_id, child_account_id)" do
    before { create(:child_board, board: board, child_account: communicator) }

    it "rejects a duplicate dashboard entry at the model layer" do
      dup = build(:child_board, board: board, child_account: communicator)
      expect(dup).not_to be_valid
      expect(dup.errors[:board_id]).to be_present
    end

    it "is enforced structurally by the unique index (validation-skipping inserts raise)" do
      expect {
        described_class.insert!({ board_id: board.id, child_account_id: communicator.id,
                                  created_at: Time.current, updated_at: Time.current })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same board on a different communicator" do
      other = create(:child_account, user: user)
      expect(build(:child_board, board: board, child_account: other)).to be_valid
    end
  end
end
