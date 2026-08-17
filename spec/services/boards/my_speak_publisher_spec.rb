require "rails_helper"

# A board on a communicator's MySpeak page has to be published, or its card
# renders to an anonymous visitor and then 404s on tap (Board#viewable_by?).
# This service is the write half of that invariant; Profile#communication_boards
# is the read half.
RSpec.describe Boards::MySpeakPublisher do
  let(:owner)        { create(:user) }
  let(:communicator) { create(:child_account, user: owner) }

  def favorited_child_board(board, favorite: true)
    # build, not create — creating with favorite: true fires ChildBoard's own
    # callback, which is what most of these examples are trying to exercise
    # directly.
    build(:child_board, board: board, child_account: communicator, favorite: favorite)
  end

  describe "#call" do
    it "publishes a favorited board owned by the page's owner" do
      board = create(:board, user: owner, published: false)

      expect(described_class.new(favorited_child_board(board)).call).to be true
      expect(board.reload.published).to be true
    end

    it "does nothing when the child_board is not a favorite" do
      board = create(:board, user: owner, published: false)

      expect(described_class.new(favorited_child_board(board, favorite: false)).call).to be false
      expect(board.reload.published).to be false
    end

    it "is a no-op for an already-published board" do
      board = create(:board, user: owner, published: true)

      expect(described_class.new(favorited_child_board(board)).call).to be false
      expect(board.reload.published).to be true
    end

    it "fills in a blank slug on the way to published" do
      board = create(:board, user: owner, published: false)
      board.update_column(:slug, "")

      described_class.new(favorited_child_board(board)).call

      expect(board.reload.slug).to be_present
    end

    # A communicator's dashboard can hold a board owned by someone else (an
    # SLP's shared team board). A parent's favorite tap is not that user's
    # consent to make their board publicly readable at /pb/<slug>.
    it "leaves a board owned by another user unpublished" do
      other_user = create(:user)
      board = create(:board, user: other_user, published: false)

      expect(described_class.new(favorited_child_board(board)).call).to be false
      expect(board.reload.published).to be false
    end
  end

  describe "cascading to the board's set" do
    it "publishes the builder set's pages along with the root" do
      root = create(:board, user: owner, published: false,
                            settings: { "builder_root" => true })
      group = BoardGroup.create!(user: owner, name: "Milo's Set", builder: true,
                                 root_board_id: root.id)
      group.board_group_boards.create!(board: root)
      page = create(:board, user: owner, published: false,
                            settings: { "builder_child" => true })
      group.board_group_boards.create!(board: page)

      described_class.new(favorited_child_board(root)).call

      expect(root.reload.published).to be true
      expect(page.reload.published).to be true
    end

    it "publishes AssignmentCloner sub-clones, which have no BoardGroup" do
      root = create(:board, user: owner, published: false)
      child = create(:board, user: owner, published: false,
                             settings: { "assignment_child" => true,
                                         "assignment_root_id" => root.id })

      described_class.new(favorited_child_board(root)).call

      expect(root.reload.published).to be true
      expect(child.reload.published).to be true
    end
  end
end
