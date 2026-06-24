# == Schema Information
#
# Table name: board_groups
#
#  id                    :bigint           not null, primary key
#  name                  :string
#  layout                :jsonb
#  predefined            :boolean          default(FALSE)
#  display_image_url     :string
#  position              :integer
#  number_of_columns     :integer          default(6)
#  user_id               :integer          not null
#  bg_color              :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  root_board_id         :integer
#  original_obf_root_id  :string
#  featured              :boolean          default(FALSE), not null
#  slug                  :string
#  small_screen_columns  :integer          default(4), not null
#  medium_screen_columns :integer          default(5), not null
#  large_screen_columns  :integer          default(6), not null
#  margin_settings       :jsonb            not null
#  settings              :jsonb            not null
#  description           :text
#  builder               :boolean          default(FALSE), not null
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
      board = Board.create(name: "Test Board", user: user, parent: user)
      board_group.add_board(board)
      board_group.save
      expect(BoardGroup.with_artifacts.first.boards.first).to eq(board)
      expect(board.board_groups).to include(board_group)
    end

    it "has multiple boards" do
      board_group = BoardGroup.create(name: "Test", user: user)
      board_1 = Board.create!(name: "Test Board 1", user: user, parent: user, slug: "test-board-1-#{SecureRandom.hex(4)}")
      board_2 = Board.create!(name: "Test Board 2", user: user, parent: user, slug: "test-board-2-#{SecureRandom.hex(4)}")
      board_group.add_board(board_1)
      board_group.add_board(board_2)
      board_group.save!
      board_group.reload

      expect(board_group.boards.count).to eq(2)
      expect(board_group.boards).to include(board_1, board_2)
      expect(board_1.board_groups).to include(board_group)
      expect(board_2.board_groups).to include(board_group)
    end
  end

  # Issue #407: a builder group OWNS its member boards, so destroying it
  # destroys every member board (fixing the orphan-on-delete bug). Hand-made
  # groups are pure collections — destroying them keeps the member boards.
  describe "cascade delete (builder vs hand-made)" do
    def builder_group_with_members(owner)
      root  = Board.create!(name: "Built Root", user: owner, parent: owner, slug: "root-#{SecureRandom.hex(4)}")
      child = Board.create!(name: "Built Child", user: owner, parent: owner, slug: "child-#{SecureRandom.hex(4)}")
      group = owner.board_groups.create!(name: "Built Set", builder: true)
      group.board_group_boards.create!(board: root)
      group.board_group_boards.create!(board: child)
      group.update!(root_board_id: root.id)
      [group, root, child]
    end

    it "destroys all member boards and join rows when a builder group is destroyed" do
      group, root, child = builder_group_with_members(user)

      expect { group.destroy! }
        .to change { Board.where(id: [root.id, child.id]).count }.from(2).to(0)
        .and change { BoardGroupBoard.where(board_group_id: group.id).count }.to(0)

      expect(BoardGroup.exists?(group.id)).to be(false)
    end

    it "destroys the builder root even though root_board_id FKs back to it" do
      group, root, _child = builder_group_with_members(user)
      # root_board_id is a no-ON-DELETE FK into a member board; the cascade must
      # null it before destroying the board or the delete would raise.
      expect(group.root_board_id).to eq(root.id)
      expect { group.destroy! }.not_to raise_error
      expect(Board.exists?(root.id)).to be(false)
    end

    it "also destroys the root's communicator ChildBoard join" do
      communicator = create(:child_account, user: user)
      group, root, _child = builder_group_with_members(user)
      cb = communicator.child_boards.create!(board: root, created_by_id: user.id)

      group.destroy!

      expect(ChildBoard.exists?(cb.id)).to be(false)
    end

    it "leaves member boards intact when a hand-made (non-builder) group is destroyed" do
      board = Board.create!(name: "Kept", user: user, parent: user, slug: "kept-#{SecureRandom.hex(4)}")
      group = user.board_groups.create!(name: "Manual Set") # builder defaults to false
      group.board_group_boards.create!(board: board)

      expect { group.destroy! }.not_to change { Board.exists?(board.id) }
      expect(Board.exists?(board.id)).to be(true)
      expect(BoardGroupBoard.where(board_group_id: group.id).count).to eq(0)
    end
  end

  describe "#display_image_url with cover_board_id" do
    let(:group) { BoardGroup.create!(name: "Group", user: user) }
    let(:cover_board) { Board.create!(name: "Cover", user: user, parent: user, slug: "cover-#{SecureRandom.hex(4)}") }

    before do
      group.add_board(cover_board)
      group.update_column(:display_image_url, "https://example.com/group-fallback.png")
      cover_board.update_column(:display_image_url, "https://example.com/cover.png")
    end

    it "returns the column value when no cover_board_id is set" do
      expect(group.display_image_url).to eq("https://example.com/group-fallback.png")
    end

    it "returns the cover board's display image when cover_board_id is set" do
      group.update!(settings: group.settings.merge("cover_board_id" => cover_board.id))
      expect(group.reload.display_image_url).to eq("https://example.com/cover.png")
    end

    it "falls back to the column when cover_board_id points at a missing board" do
      group.update!(settings: group.settings.merge("cover_board_id" => 999999))
      expect(group.reload.display_image_url).to eq("https://example.com/group-fallback.png")
    end
  end
end
