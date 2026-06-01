# frozen_string_literal: true

require "rails_helper"

# Issues #212 and #213 — authorization on `/api/child_boards/:id`.
#
# Two different rules apply to the two mutating actions:
#
# - **#destroy** (detach a board from the communicator) is **owner-only**.
#   An SLP supervisor who shared a board can NOT detach it directly,
#   because that bypasses `TeamUser#before_destroy`'s snapshot safety net.
#   To stop sharing, the supervisor removes herself from the team, which
#   triggers the snapshot copy onto the family.
#
# - **#update / #toggle_favorite** (the favorite flag, plus any other
#   curation-tier field on the join row) follow the **curation rule** —
#   the account owner, anyone with admin/supervisor on the team, and
#   system admins. Same rule as `assign_boards`. Plain `member` is
#   read-only on the communicator and is rejected (issue #216).
#
# Full matrix: marketing/.claude-notes/handoff-workflow.md
RSpec.describe "API::ChildBoards owner protection", type: :request do
  let(:parent) { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_parent_stub") }
  let(:slp)    { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_slp_stub") }

  # Post-claim shape: the parent owns the communicator. The SLP is on
  # the team as a supervisor. The board that's attached to the
  # communicator is owned by the SLP — i.e. a board she's sharing in.
  let!(:child_account) do
    create(:child_account,
           user: parent,
           owner: parent,
           status: ChildAccount::ACTIVE,
           passcode: "ownerpw1")
  end
  let!(:team) do
    t = child_account.ensure_team!(creator: slp)
    t.add_member!(parent, "admin")
    t.add_member!(slp, "supervisor")
    t
  end
  let(:slp_board) { create(:board, user: slp, name: "Shared by SLP") }
  let!(:child_board) { create(:child_board, board: slp_board, child_account: child_account) }

  describe "DELETE /api/child_boards/:id (detach)" do
    it "lets the communicator owner detach the board" do
      expect {
        delete "/api/child_boards/#{child_board.id}", headers: auth_headers(parent)
      }.to change { ChildBoard.where(id: child_board.id).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
    end

    it "blocks the SLP supervisor from detaching the board she shared (403)" do
      expect {
        delete "/api/child_boards/#{child_board.id}", headers: auth_headers(slp)
      }.not_to change { ChildBoard.where(id: child_board.id).count }

      expect(response).to have_http_status(:forbidden)
    end

    it "lets a system admin detach (escape hatch)" do
      admin = create(:admin_user)
      expect {
        delete "/api/child_boards/#{child_board.id}", headers: auth_headers(admin)
      }.to change { ChildBoard.where(id: child_board.id).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /api/child_boards/:id (favorite toggle)" do
    let(:admin_member) { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_admin_member_stub") }

    before do
      team.add_member!(admin_member, "admin")
    end

    it "lets the communicator owner toggle favorite" do
      patch "/api/child_boards/#{child_board.id}",
            params: { child_board: { favorite: true } },
            headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      expect(child_board.reload.favorite).to eq(true)
    end

    it "lets a team admin (non-owner) toggle favorite" do
      patch "/api/child_boards/#{child_board.id}",
            params: { child_board: { favorite: true } },
            headers: auth_headers(admin_member)

      expect(response).to have_http_status(:ok)
      expect(child_board.reload.favorite).to eq(true)
    end

    it "lets the SLP supervisor toggle favorite (curation tier, issue #216)" do
      patch "/api/child_boards/#{child_board.id}",
            params: { child_board: { favorite: true } },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      expect(child_board.reload.favorite).to eq(true)
    end

    it "blocks a plain `member` from toggling favorite (read-only, issue #216)" do
      plain_member = create(:user, created_at: 2.months.ago)
      team.add_member!(plain_member, "member")
      patch "/api/child_boards/#{child_board.id}",
            params: { child_board: { favorite: true } },
            headers: auth_headers(plain_member)

      expect(response).to have_http_status(:forbidden)
      expect(child_board.reload.favorite).to eq(false)
    end
  end
end
