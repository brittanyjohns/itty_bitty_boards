# == Schema Information
#
# Table name: board_groups
#
#  id                   :bigint           not null, primary key
#  name                 :string
#  layout               :jsonb
#  predefined           :boolean          default(FALSE)
#  display_image_url    :string
#  position             :integer
#  number_of_columns    :integer          default(6)
#  user_id              :integer          not null
#  bg_color             :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  root_board_id        :integer
#  original_obf_root_id :string
#
require "rails_helper"

RSpec.describe BoardGroup, type: :model do
  let!(:user) { User.create!(email: "test@test.com", password: "password") }
  describe "new board group" do
    it "should have a name" do
      board_group = BoardGroup.new(name: nil, user: user)
      board_group.valid?
      expect(board_group.errors[:name]).to include("can't be blank")
    end
    it "should be valid with a name" do
      board_group = BoardGroup.create(name: "Test", user: user)
      expect(board_group).to be_valid
    end
  end

  describe "with boards" do
    it "should include images and board_images" do
      board_group = BoardGroup.create(name: "Test", user: user)
      board = Board.create(name: "Test Board", user: user, parent: user, board_group: board_group)
      board_group.add_board(board)
      board_group.save
      expect(BoardGroup.with_artifacts.first.boards.first).to eq(board)
      expect(board.board_group).to eq(board_group)
    end

    it "has multiple boards" do
      board_group = BoardGroup.create(name: "Test", user: user)
      board_1 = Board.create!(name: "Test Board 1", user: user, parent: user, board_group: board_group)
      board_2 = Board.create!(name: "Test Board 2", user: user, parent: user, board_group: board_group)
      board_group.save!
      board_group.reload

      expect(board_group.boards.count).to eq(2)
      expect(board_group.boards.first).to eq(board_1)
      expect(board_1.board_group).to eq(board_group)
      expect(board_2.board_group).to eq(board_group)
      expect(board_group.boards.last).to eq(board_2)
    end
  end
end
