# frozen_string_literal: true

require "rails_helper"

# Issue #923 (finding 2) — every team role is a legitimate READER of the
# boards on a communicator's dashboard.
#
# `Board#viewable_by?` granted a non-owner access by exactly two routes: a
# `team_boards` shelf row, or `team_curatable_by?`, which is gated on
# `User::CURATE_ROLES`. A board attached to a communicator's dashboard sits
# on neither for a `member`/`restricted` invitee — so a grandparent invited
# as Support precisely so she could help with the child's board joined the
# team and saw the communicator with zero boards. The two roles that mean
# "use it, don't change it" were the two that could not use anything.
#
# This mirrors `ChildAccount#viewable_by?`, which already says every team
# role reads. Reading is reachability-based, exactly as curating is, so a
# folder page carrying no `child_boards` row of its own is covered too.
RSpec.describe "Board team reading", type: :model do
  let(:parent)     { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:slp)        { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:support)    { create(:user, created_at: 2.months.ago) }
  let(:restricted) { create(:user, created_at: 2.months.ago) }
  let(:stranger)   { create(:user, created_at: 2.months.ago) }

  let!(:account) do
    create(:child_account, user: parent, owner: parent, status: ChildAccount::ACTIVE)
  end

  # Assignment attaches the ROOT of a set; its folder pages carry no
  # `child_boards` row, which is why an attachment-only answer half-works.
  let!(:root_board) { create(:board, user: parent) }
  let!(:sub_board)  { create(:board, user: parent) }
  let!(:folder_tile) do
    create(:board_image, board: root_board, predictive_board_id: sub_board.id)
  end
  let!(:child_board) { create(:child_board, board: root_board, child_account: account) }

  let!(:team) do
    t = account.ensure_team!(creator: parent)
    t.upsert_member!(slp, "supervisor")
    t.upsert_member!(support, "member")
    t.upsert_member!(restricted, "restricted")
    t
  end

  describe "Board#viewable_by?" do
    it "lets a Support (member) invitee read a dashboard-attached board" do
      expect(root_board.viewable_by?(support)).to be true
    end

    it "lets a Read-Only (restricted) invitee read a dashboard-attached board" do
      expect(root_board.viewable_by?(restricted)).to be true
    end

    it "reaches the folder pages of that board, which carry no child_boards row" do
      expect(sub_board.child_accounts).to be_empty
      expect(sub_board.viewable_by?(support)).to be true
      expect(sub_board.viewable_by?(restricted)).to be true
    end

    it "still lets a supervisor read it" do
      expect(root_board.viewable_by?(slp)).to be true
    end

    it "still lets the owner read their own board" do
      expect(root_board.viewable_by?(parent)).to be true
    end

    it "refuses someone with no team relationship to the board" do
      expect(root_board.viewable_by?(stranger)).to be false
      expect(sub_board.viewable_by?(stranger)).to be false
    end

    it "refuses a logged-out visitor on an unpublished board" do
      expect(root_board.viewable_by?(nil)).to be false
    end

    it "does not reach a board of the owner's that is on no shared dashboard" do
      private_board = create(:board, user: parent)
      expect(private_board.viewable_by?(support)).to be false
    end

    it "refuses a folder tile pointing at a board outside the household" do
      outsider_board = create(:board, user: stranger)
      create(:board_image, board: root_board, predictive_board_id: outsider_board.id)

      expect(outsider_board.viewable_by?(support)).to be false
    end

    # The production state this issue was filed against (team 253): the board
    # was attached BEFORE `ChildBoard#register_on_communicator_team` existed,
    # so no `team_boards` row was ever written and route 1 is false for
    # everybody. Reachability answers it with no data migration.
    context "when the board predates team registration (no team_boards row)" do
      before { team.team_boards.destroy_all }

      it "still lets a Support (member) invitee read it" do
        expect(team.reload.boards).to be_empty
        expect(root_board.viewable_by?(support)).to be true
      end

      it "still lets a Read-Only (restricted) invitee read it" do
        expect(root_board.viewable_by?(restricted)).to be true
      end

      it "still refuses a stranger" do
        expect(root_board.viewable_by?(stranger)).to be false
      end
    end

    it "revokes the read when the member leaves the team" do
      expect(root_board.viewable_by?(support)).to be true

      TeamUser.find_by(team: team, user: support).destroy!
      support.reset_team_curation!

      expect(root_board.viewable_by?(support)).to be false
    end
  end

  # Reading is widened; writing is not. `TEAM_CURATION_ACTIONS` and the
  # no-delete rule are unchanged.
  describe "edit rights are unchanged" do
    it "still refuses a Support (member) role" do
      expect(root_board.can_edit_for(support)).to be false
      expect(sub_board.can_edit_for(support)).to be false
    end

    it "still refuses a Read-Only (restricted) role" do
      expect(root_board.can_edit_for(restricted)).to be false
    end

    it "still lets a supervisor edit" do
      expect(root_board.can_edit_for(slp)).to be true
    end

    it "does not make a reader team-curatable" do
      expect(root_board.team_curatable_by?(support)).to be false
      expect(root_board.team_curatable_by?(restricted)).to be false
    end
  end
end
