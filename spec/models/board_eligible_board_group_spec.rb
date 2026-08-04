require "rails_helper"

RSpec.describe Board, "#eligible_board_group" do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  it "returns nil when the board belongs to no group" do
    expect(board.eligible_board_group).to be_nil
  end

  it "returns a builder group over a non-predefined group when both exist" do
    plain_group = create(:board_group, user: user, builder: false, predefined: false)
    plain_group.add_board(board)
    builder_group = create(:board_group, user: user, builder: true)
    builder_group.add_board(board)

    expect(board.eligible_board_group).to eq(builder_group)
  end

  it "returns a non-predefined, non-builder group" do
    group = create(:board_group, user: user, builder: false, predefined: false)
    group.add_board(board)

    expect(board.eligible_board_group).to eq(group)
  end

  it "ignores a predefined, non-builder group" do
    group = create(:board_group, user: user, builder: false, predefined: true)
    group.add_board(board)

    expect(board.eligible_board_group).to be_nil
  end
end
