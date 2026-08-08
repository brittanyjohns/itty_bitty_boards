require "rails_helper"

RSpec.describe BoardPrintable do
  it "is destroyed along with its board" do
    board = FactoryBot.create(:board)
    printable = described_class.create!(board: board, board_ids: [board.id])

    expect { board.destroy! }.not_to raise_error
    expect(described_class.exists?(printable.id)).to be false
  end
end
