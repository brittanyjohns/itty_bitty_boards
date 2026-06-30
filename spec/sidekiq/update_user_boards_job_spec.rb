require "rails_helper"

RSpec.describe UpdateUserBoardsJob, type: :job do
  describe "#perform" do
    let(:user) { FactoryBot.create(:user) }
    let(:cloned_board) { FactoryBot.create(:board, user: user) }
    let(:source_board) { FactoryBot.create(:board, user: user) }

    it "repoints the user's board images at the cloned board" do
      expect(Board).to receive(:find_by).with(id: cloned_board.id).and_return(cloned_board)
      expect(Board).to receive(:find_by).with(id: source_board.id).and_return(source_board)
      expect(cloned_board).to receive(:update_user_boards_after_cloning).with(source_board, cloned_board.user_id)

      described_class.new.perform(cloned_board.id, source_board.id)
    end

    it "no-ops when the cloned board was deleted between enqueue and run" do
      expect {
        described_class.new.perform(-1, source_board.id)
      }.not_to raise_error
    end

    it "no-ops when the source board was deleted between enqueue and run" do
      expect {
        described_class.new.perform(cloned_board.id, -1)
      }.not_to raise_error
    end
  end
end
