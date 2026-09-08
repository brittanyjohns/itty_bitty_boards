require "rails_helper"

# Quick-add offers a board and then writes to it, and this object is the single
# answer to both halves. Two questions live here and they are NOT the same:
#
#   * membership (`include?`) is ENFORCED — a board reached only through a
#     folder tile aimed at somebody else's account is refused;
#   * sharing (`shared?`) is ADVISORY — nobody is blocked for it, it drives a
#     badge and a client-side confirm.
#
# Assignment attaches the ROOT of a set and its pages carry no child_boards row,
# so both answers follow reachability rather than attachment.
RSpec.describe Boards::QuickAddScope do
  let(:owner) { create(:user) }
  let(:communicator) { create(:child_account, user: owner, name: "Leo") }

  def board(name, user: owner)
    create(:board, user: user, name: name)
  end

  def link(from, to, data: {})
    create(:board_image, board: from, predictive_board_id: to.id, data: data)
  end

  def attach(board, account)
    create(:child_board, board: board, child_account: account)
  end

  describe "membership" do
    it "offers a sub-page that has no child_boards row of its own" do
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      attach(root, communicator)

      scope = described_class.new(communicator)

      expect(scope.board_ids).to contain_exactly(root.id, page.id)
      expect(scope.include?(page.id)).to be(true)
    end

    it "reaches a page several folders deep" do
      root = board("Core 84")
      page = board("Food")
      deep = board("Snacks")
      link(root, page)
      link(page, deep)
      attach(root, communicator)

      expect(described_class.new(communicator).board_ids)
        .to contain_exactly(root.id, page.id, deep.id)
    end

    # The security control. board_images permits predictive_board_id without
    # validating the target and board ids are sequential, so a tile can point
    # anywhere. Attachment-based access made that inert; reachability does not.
    it "refuses a board reached only through a tile aimed at another account" do
      stranger = create(:user)
      victim = board("Private Board", user: stranger)
      beyond = board("Further In", user: stranger)
      link(victim, beyond)

      root = board("Mine")
      link(root, victim)
      attach(root, communicator)

      scope = described_class.new(communicator)

      expect(scope.board_ids).to eq([root.id])
      expect(scope.include?(victim.id)).to be(false)
      expect(scope.include?(beyond.id)).to be(false)
    end

    it "excludes an admin-owned public board even when it is attached" do
      admin = create(:admin_user)
      public_board = create(:board, user: admin, name: "Core Words",
                                    predefined: true, published: true)
      attach(public_board, communicator)

      expect(described_class.new(communicator).include?(public_board.id)).to be(false)
    end

    it "includes a board the communicator's team shares" do
      slp = create(:user)
      team = create(:team, created_by: slp)
      shared_board = board("Classroom Core", user: slp)
      TeamBoard.create!(team: team, board: shared_board)
      TeamAccount.create!(team: team, account: communicator)
      attach(shared_board, communicator)

      expect(described_class.new(communicator).include?(shared_board.id)).to be(true)
    end

    it "includes boards owned by the communicator's supervising owner" do
      slp = create(:user)
      lent = create(:child_account, user: owner, owner: slp, name: "Maya")
      lent_board = board("SLP Board", user: slp)
      attach(lent_board, lent)

      expect(described_class.new(lent).include?(lent_board.id)).to be(true)
    end

    it "offers a user their own boards and nobody else's" do
      mine = board("Mine")
      theirs = board("Theirs", user: create(:user))

      scope = described_class.new(owner)

      expect(scope.include?(mine.id)).to be(true)
      expect(scope.include?(theirs.id)).to be(false)
    end
  end

  describe "sharing" do
    it "is false for a board only this communicator uses" do
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      attach(root, communicator)

      scope = described_class.new(communicator)

      expect(scope.shared?(root.id)).to be(false)
      expect(scope.shared?(page.id)).to be(false)
    end

    # The whole reason sharing follows reachability. The sibling opens the same
    # "Food" page by tapping the folder, so a word added there reaches them
    # exactly as it would on the root.
    it "makes a sub-page inherit sharing from the root that reaches it" do
      sibling = create(:child_account, user: owner, name: "Maya")
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      attach(root, communicator)
      attach(root, sibling)

      scope = described_class.new(communicator)

      expect(scope.shared?(root.id)).to be(true)
      expect(scope.shared?(page.id)).to be(true)
    end

    it "stops being shared once the other dashboard detaches" do
      sibling = create(:child_account, user: owner, name: "Maya")
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      attach(root, communicator)
      other = attach(root, sibling)

      expect(described_class.new(communicator).shared?(page.id)).to be(true)

      other.destroy!

      expect(described_class.new(communicator).shared?(page.id)).to be(false)
    end

    # Without the child_accounts join an archived sibling marks the board
    # shared forever and the badge never comes off.
    it "ignores an archived communicator" do
      sibling = create(:child_account, user: owner, name: "Maya")
      root = board("Core 84")
      attach(root, communicator)
      attach(root, sibling)
      sibling.update_columns(archived_at: Time.current)

      expect(described_class.new(communicator).shared?(root.id)).to be(false)
    end

    it "is not triggered by a team share" do
      team = create(:team, created_by: owner)
      root = board("Core 84")
      attach(root, communicator)
      TeamBoard.create!(team: team, board: root)

      expect(described_class.new(communicator).shared?(root.id)).to be(false)
    end

    it "is not triggered by publishing" do
      root = board("Core 84")
      attach(root, communicator)
      root.update!(published: true)

      expect(described_class.new(communicator).shared?(root.id)).to be(false)
    end

    it "never counts the acting communicator as somebody else" do
      root = board("Core 84")
      attach(root, communicator)

      expect(described_class.new(communicator).shared?(root.id)).to be(false)
    end

    it "does not blow up on a board nothing reaches" do
      loose = board("Unattached")

      expect(described_class.new(owner).shared?(loose.id)).to be(false)
    end
  end

  describe "a user's view of sharing" do
    it "reports a board on one of their communicators' dashboards as shared" do
      root = board("Core 84")
      attach(root, communicator)

      expect(described_class.new(owner).shared?(root.id)).to be(true)
    end

    it "excludes the acting communicator when one is named" do
      root = board("Core 84")
      attach(root, communicator)

      scope = described_class.new(owner, acting_communicator: communicator)

      expect(scope.shared?(root.id)).to be(false)
    end

    it "still reports sharing when a second communicator has it" do
      sibling = create(:child_account, user: owner, name: "Maya")
      root = board("Core 84")
      attach(root, communicator)
      attach(root, sibling)

      scope = described_class.new(owner, acting_communicator: communicator)

      expect(scope.shared?(root.id)).to be(true)
    end

    it "reports sharing on a sub-page of a shared root" do
      sibling = create(:child_account, user: owner, name: "Maya")
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      attach(root, communicator)
      attach(root, sibling)

      expect(described_class.new(owner).shared?(page.id)).to be(true)
    end

    # A stranger who assigned this user's published board is real sharing, but
    # naming a number for them would make the badge noise.
    it "counts only communicators the user may know about" do
      stranger_account = create(:child_account, user: create(:user), name: "Wilhelmina")
      root = board("Core 84")
      attach(root, stranger_account)

      scope = described_class.new(owner)

      expect(scope.shared?(root.id)).to be(true)
      # Board#in_use_by is scoped to communicators the viewer owns, so it says
      # nothing here. That gap is exactly what this boolean covers.
      expect(root.in_use_by(owner)).to be_nil
    end

    it "answers a communicator with a plain boolean" do
      sibling = create(:child_account, user: owner, name: "Maya")
      root = board("Core 84")
      attach(root, communicator)
      attach(root, sibling)

      expect(described_class.new(communicator).shared?(root.id)).to be(true)
    end
  end

  describe "grouping and caps" do
    it "attributes a page to the dashboard root that reaches it" do
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      attach(root, communicator)

      expect(described_class.new(communicator).root_ids_for(page.id)).to eq([root.id])
    end

    it "reports truncation and keeps include? matching board_ids exactly" do
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      attach(root, communicator)

      scope = described_class.new(communicator, limit: 1)

      expect(scope.truncated?).to be(true)
      expect(scope.board_ids).to eq([root.id])
      expect(scope.include?(page.id)).to be(false)
    end

    it "terminates on a back-tile cycle" do
      root = board("Core 84")
      page = board("Food")
      link(root, page)
      link(page, root, data: { "back_tile" => true })
      attach(root, communicator)

      expect(described_class.new(communicator).board_ids)
        .to contain_exactly(root.id, page.id)
    end

    it "answers nothing for a communicator with no dashboard" do
      expect(described_class.new(communicator).board_ids).to be_empty
    end
  end
end
