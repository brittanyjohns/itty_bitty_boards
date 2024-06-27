require "rails_helper"

RSpec.describe Board, type: :model do
  context "validation" do
    let(:user) { FactoryBot.create(:user) }
    subject(:board) { FactoryBot.build(:board, name: nil, user: user) }
    it "is invalid without a name" do
      puts "board: #{board.inspect}"
      expect(board.save).to be_falsey
    end

    it "is valid with user and name" do
      board.name = "Some name"
      expect(board.save!).to be_truthy
    end
  end
end
