require "rails_helper"

RSpec.describe Boards::ExportScope do
  let(:user)    { create(:user) }
  let(:stranger) { create(:user) }

  def link(from_board, to_board)
    image = create(:image, label: "go_#{to_board.id}", user: user)
    from_board.board_images.create!(image_id: image.id, position: from_board.board_images.count,
                                    predictive_board_id: to_board.id, skip_create_voice_audio: true)
  end

  describe ".for_board" do
    it "returns the root first, followed by linked boards" do
      root  = create(:board, user: user, name: "Root")
      child = create(:board, user: user, name: "Child")
      link(root, child)

      result = described_class.for_board(root.reload, exporting_user: user)

      expect(result.root).to eq(root)
      expect(result.boards.first).to eq(root)
      expect(result.boards).to include(child)
    end

    it "does not loop on a cycle" do
      a = create(:board, user: user, name: "A")
      b = create(:board, user: user, name: "B")
      link(a, b)
      link(b, a)

      result = described_class.for_board(a.reload, exporting_user: user)

      expect(result.boards.map(&:id).uniq.size).to eq(result.boards.size)
      expect(result.boards.size).to eq(2)
    end

    it "skips a linked board the user may not read" do
      root   = create(:board, user: user, name: "Root")
      hidden = create(:board, user: stranger, name: "Hidden", published: false)
      link(root, hidden)

      result = described_class.for_board(root.reload, exporting_user: user)

      expect(result.boards).not_to include(hidden)
      expect(result.skipped_boards.first[:board_id]).to eq(hidden.id)
    end

    it "caps the number of boards and records the overflow" do
      stub_const("Boards::ExportScope::MAX_BOARDS", 2)
      root = create(:board, user: user, name: "Root")
      3.times { |i| link(root, create(:board, user: user, name: "C#{i}")) }

      result = described_class.for_board(root.reload, exporting_user: user)

      expect(result.boards.size).to eq(2)
      expect(result.skipped_boards).not_to be_empty
    end
  end

  describe ".for_group" do
    it "returns the group's boards with the root board first" do
      group = create(:board_group, user: user)
      first = create(:board, user: user, name: "One")
      second = create(:board, user: user, name: "Two")
      group.add_board(first)
      group.add_board(second)
      group.update!(root_board_id: second.id)

      result = described_class.for_group(group.reload, exporting_user: user)

      expect(result.root).to eq(second)
      expect(result.boards.first).to eq(second)
      expect(result.boards.map(&:id)).to match_array([first.id, second.id])
    end
  end
end
