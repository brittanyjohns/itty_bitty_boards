# frozen_string_literal: true

require "rails_helper"

# Issue #889 — a Supervisor on a communicator's team may edit the boards on
# that communicator's dashboard. Board editing used to be owner-or-sysadmin
# only, so the school SLP a parent invited specifically to add vocabulary
# could only "Copy & customize" — forking a school copy away from the home
# copy, which is the divergence the team feature exists to prevent.
RSpec.describe "Board team curation", type: :model do
  let(:parent)     { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:slp)        { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:support)    { create(:user, created_at: 2.months.ago) }
  let(:restricted) { create(:user, created_at: 2.months.ago) }
  let(:stranger)   { create(:user, created_at: 2.months.ago) }

  let!(:account) do
    create(:child_account, user: parent, owner: parent, status: ChildAccount::ACTIVE)
  end

  # The board the family put on the dashboard, plus a folder page hanging off
  # it. Assignment attaches the ROOT only, so the page has no child_boards row.
  let!(:root_board) { create(:board, user: parent) }
  let!(:sub_board)  { create(:board, user: parent) }
  let!(:folder_tile) do
    create(:board_image, board: root_board, predictive_board_id: sub_board.id)
  end
  let!(:child_board) { create(:child_board, board: root_board, child_account: account) }

  let!(:team) do
    t = account.ensure_team!(creator: parent)
    t.upsert_member!(parent, "admin")
    t.upsert_member!(slp, "supervisor")
    t.upsert_member!(support, "member")
    t.upsert_member!(restricted, "restricted")
    t
  end

  describe "Board#can_edit_for" do
    it "lets a supervisor edit a board attached to a communicator they curate" do
      expect(root_board.can_edit_for(slp)).to be true
    end

    it "reaches the folder pages of that board, which carry no child_boards row" do
      expect(sub_board.child_accounts).to be_empty
      expect(sub_board.can_edit_for(slp)).to be true
    end

    it "still lets the owner edit their own board" do
      expect(root_board.can_edit_for(parent)).to be true
    end

    it "refuses a Support (member) role" do
      expect(root_board.can_edit_for(support)).to be false
      expect(sub_board.can_edit_for(support)).to be false
    end

    it "refuses a Read-Only (restricted) role" do
      expect(root_board.can_edit_for(restricted)).to be false
    end

    it "refuses someone with no team relationship to the board" do
      expect(root_board.can_edit_for(stranger)).to be false
    end

    it "does not reach a board of the owner's that is on no shared dashboard" do
      private_board = create(:board, user: parent)
      expect(private_board.can_edit_for(slp)).to be false
    end

    it "refuses a folder tile pointing at a board outside the household" do
      outsider_board = create(:board, user: stranger)
      create(:board_image, board: root_board, predictive_board_id: outsider_board.id)

      expect(outsider_board.can_edit_for(slp)).to be false
    end

    it "revokes the grant when the supervisor leaves the team" do
      expect(root_board.can_edit_for(slp)).to be true

      TeamUser.find_by(team: team, user: slp).destroy!
      slp.reset_team_curation!

      expect(root_board.can_edit_for(slp)).to be false
      # The family keeps the board either way — it was always theirs.
      expect(root_board.reload.user_id).to eq(parent.id)
      expect(root_board.can_edit_for(parent)).to be true
    end

    it "revokes the grant when the supervisor is demoted to Support" do
      team.upsert_member!(slp, "member")
      slp.reset_team_curation!

      expect(root_board.can_edit_for(slp)).to be false
    end

    context "when the board is read-only under its OWNER's plan" do
      before do
        allow(root_board).to receive(:user).and_return(parent)
        allow(parent).to receive(:board_editable?).with(root_board).and_return(false)
      end

      it "is not a lock bypass for the supervisor" do
        expect(root_board.can_edit_for(slp)).to be false
      end

      it "still reports the membership grant separately" do
        expect(root_board.team_curatable_by?(slp)).to be true
      end
    end
  end

  describe "Boards::TeamCuration" do
    it "seeds from the communicators the user curates" do
      expect(slp.team_curation.curated_account_ids).to include(account.id)
      expect(support.team_curation.curated_account_ids).to be_empty
    end

    it "returns nothing, and asks nothing of the graph, for a user on no team" do
      expect(stranger.team_curation.board_ids).to be_empty
      expect(stranger.team_curation).not_to be_truncated
    end
  end
end
