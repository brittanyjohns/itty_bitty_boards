# frozen_string_literal: true

require "rails_helper"

# Per-board edit rights. A team grants VIEWING; a per-board GRANT
# (`team_boards.allow_edit`), made by the board's OWNER, grants content
# editing. Role says WHO on the team it reaches, the grant says WHICH board —
# both are required, and both are checked on the SAME team.
RSpec.describe Board, "team edit grants" do
  let(:owner) { create(:user, plan_type: "pro") }
  let(:board) { create(:board, user: owner) }

  let(:communicator) { create(:child_account, user: owner, owner: owner) }
  let!(:team) { communicator.ensure_team!(creator: owner) }

  def member_on(team_record, role)
    create(:user, plan_type: "pro").tap { |u| team_record.upsert_member!(u, role) }
  end

  def grant!(board_record, team_record)
    team_record.add_board!(board_record, board_record.user_id)
    TeamBoard.find_by(board_id: board_record.id, team_id: team_record.id)
             .update!(allow_edit: true)
  end

  describe "#editable_by?" do
    it "is true for the owner" do
      expect(board.editable_by?(owner)).to be true
    end

    it "is true for a system admin" do
      expect(board.editable_by?(create(:admin_user))).to be true
    end

    it "is false for a stranger" do
      expect(board.editable_by?(create(:user))).to be false
    end

    %w[admin supervisor].each do |role|
      it "is true for a granted #{role}" do
        member = member_on(team, role)
        grant!(board, team)

        expect(board.reload.editable_by?(member)).to be true
      end
    end

    # Support is already denied the WEAKER act (curating a dashboard), so
    # granting it the stronger one would invert the ladder the invite screen
    # promises. Read-Only is out by definition.
    %w[member restricted].each do |role|
      it "is false for a granted #{role}" do
        member = member_on(team, role)
        grant!(board, team)

        expect(board.reload.editable_by?(member)).to be false
      end
    end

    it "is false for a supervisor when the board is shared but NOT granted" do
      member = member_on(team, "supervisor")
      team.add_board!(board, owner.id)

      expect(board.reload.editable_by?(member)).to be false
    end

    it "is false when the role and the grant are on DIFFERENT teams" do
      other_communicator = create(:child_account, user: owner, owner: owner)
      other_team = other_communicator.ensure_team!(creator: owner)

      member = member_on(other_team, "supervisor") # supervisor on team B
      grant!(board, team)                          # granted on team A

      expect(board.reload.editable_by?(member)).to be false
    end

    it "is false for a non-User viewer" do
      grant!(board, team)

      expect(board.reload.editable_by?(communicator)).to be false
    end

    # `predefined` boards and anything the seed admin owns are shared library
    # rows — not one person's to hand out.
    it "never grants on a predefined board" do
      member = member_on(team, "supervisor")
      catalogue = create(:board, user: owner, predefined: true)
      grant!(catalogue, team)

      expect(catalogue.reload.editable_by?(member)).to be false
    end

    describe "revocation" do
      let!(:member) { member_on(team, "supervisor") }
      before { grant!(board, team) }

      it "ends when allow_edit is cleared" do
        TeamBoard.find_by(board_id: board.id, team_id: team.id).update!(allow_edit: false)

        expect(board.reload.editable_by?(member)).to be false
      end

      it "ends when the role is downgraded, without touching the grant" do
        team.upsert_member!(member, "member")

        expect(TeamBoard.find_by(board_id: board.id, team_id: team.id).allow_edit).to be true
        expect(board.reload.editable_by?(member)).to be false
      end
    end
  end

  # Regression: the old shape compared `user_id == viewing_user.id` before
  # checking the class, and `ChildAccount#admin?` delegates to `user.admin?` —
  # so every communicator belonging to a sysadmin read `can_edit: true` on
  # every board in the system.
  describe "#can_edit_for with a ChildAccount viewer" do
    it "is false for a sysadmin's communicator" do
      sysadmin = create(:admin_user)
      their_communicator = create(:child_account, user: sysadmin, owner: sysadmin)

      expect(board.can_edit_for(their_communicator)).to be false
    end
  end

  describe "#can_edit_for" do
    it "is permission AND the owner's plan lock" do
      member = member_on(team, "supervisor")
      grant!(board, team)
      expect(board.reload.can_edit_for(member)).to be true

      allow_any_instance_of(Board).to receive(:owner_plan_allows_edit?).and_return(false)
      expect(Board.find(board.id).can_edit_for(member)).to be false
    end
  end

  describe "#edit_grant_manageable_by?" do
    it "is the board's owner or a sysadmin, never the team's owner" do
      team_owner = member_on(team, "admin")

      expect(board.edit_grant_manageable_by?(owner)).to be true
      expect(board.edit_grant_manageable_by?(create(:admin_user))).to be true
      expect(board.edit_grant_manageable_by?(team_owner)).to be false
    end
  end
end
