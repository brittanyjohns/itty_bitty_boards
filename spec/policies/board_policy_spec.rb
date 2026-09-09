require "rails_helper"

RSpec.describe BoardPolicy do
  # `#edit?` and `#update?` used to live on this policy and granted edit via
  # `user.current_team_boards.include?(record)` — no team role, no per-board
  # grant, no ownership. Nothing calls Pundit's `authorize` on a Board (only
  # `policy_scope`), so they were dead, but they said the opposite of what the
  # controllers enforce and would have handed every member of every team write
  # access to every board on it the day someone wired them up.
  #
  # Board write permission has one home: `Board#can_edit_for` (the published
  # flag) and `API::BoardsController#check_board_view_edit_permissions` (the
  # gate). Covered by spec/requests/api/boards_write_permission_spec.rb and
  # spec/models/board_read_only_spec.rb.
  it "never grants edit through team membership" do
    owner = create(:user)
    member = create(:user)
    account = create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
    team = account.ensure_team!(creator: owner)
    team.upsert_member!(member, "supervisor")

    board = create(:board, user: owner)
    team.add_board!(board, owner.id)

    policy = described_class.new(User.find(member.id), board)
    expect(policy.update?).to be false
    expect(policy.edit?).to be false
  end

  describe BoardPolicy::Scope do
    it "returns no boards for a nil user rather than raising" do
      create(:board, user: create(:user))

      expect { described_class.new(nil, Board.all).resolve }.not_to raise_error
      expect(described_class.new(nil, Board.all).resolve).to be_empty
    end

    it "returns only the user's own boards" do
      user = create(:user)
      own = create(:board, user: user, board_type: "user")
      create(:board, user: create(:user), board_type: "user")

      expect(described_class.new(user, Board.all).resolve).to contain_exactly(own)
    end
  end
end
