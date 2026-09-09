# frozen_string_literal: true

require "rails_helper"

# Issue #889, Part 2 — PATCH /api/teams/:id/member_role.
#
# Correcting a role used to mean remove-and-re-invite, which fires
# TeamUser#snapshot_shared_boards_to_family on the destroy. This updates the
# row in place: no membership churn, no snapshot, no second invite.
RSpec.describe "API::Teams member_role", type: :request do
  let(:parent)   { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:slp)      { create(:user, created_at: 2.months.ago) }
  let(:stranger) { create(:user, created_at: 2.months.ago) }

  let!(:account) do
    create(:child_account, user: parent, owner: parent, status: ChildAccount::ACTIVE)
  end

  let!(:team) do
    t = account.ensure_team!(creator: parent)
    t.upsert_member!(parent, "admin")
    t.upsert_member!(slp, "member")
    t
  end

  def slp_role
    TeamUser.find_by(team: team, user: slp).reload.role
  end

  it "lets the team owner promote a Support member to Supervisor" do
    expect {
      patch "/api/teams/#{team.id}/member_role",
            params: { user_id: slp.id, role: "supervisor" },
            headers: auth_headers(parent)
    }.not_to change { TeamUser.where(team: team).count }

    expect(response).to have_http_status(:ok)
    expect(slp_role).to eq("supervisor")

    body = JSON.parse(response.body)
    member = body["members"].detect { |m| m["user_id"] == slp.id }
    expect(member["role"]).to eq("supervisor")
  end

  it "identifies the member by email as well" do
    patch "/api/teams/#{team.id}/member_role",
          params: { email: slp.email, role: "restricted" },
          headers: auth_headers(parent)

    expect(response).to have_http_status(:ok)
    expect(slp_role).to eq("restricted")
  end

  it "never snapshots boards — the membership row is updated, not destroyed" do
    expect(BoardSnapshotService).not_to receive(:snapshot_for_removed_member)

    patch "/api/teams/#{team.id}/member_role",
          params: { user_id: slp.id, role: "supervisor" },
          headers: auth_headers(parent)

    expect(response).to have_http_status(:ok)
  end

  it "refuses a non-owner member with a coded 403" do
    patch "/api/teams/#{team.id}/member_role",
          params: { user_id: slp.id, role: "supervisor" },
          headers: auth_headers(slp)

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
    expect(slp_role).to eq("member")
  end

  it "refuses someone with no relationship to the team" do
    patch "/api/teams/#{team.id}/member_role",
          params: { user_id: slp.id, role: "supervisor" },
          headers: auth_headers(stranger)

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
  end

  it "refuses the admin role — that one is the team owner's and is server-side only" do
    patch "/api/teams/#{team.id}/member_role",
          params: { user_id: slp.id, role: "admin" },
          headers: auth_headers(parent)

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("cannot_assign_admin")
    expect(slp_role).to eq("member")
  end

  it "refuses a role outside ASSIGNABLE_ROLES with 422 invalid_role" do
    patch "/api/teams/#{team.id}/member_role",
          params: { user_id: slp.id, role: "owner" },
          headers: auth_headers(parent)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to eq("invalid_role")
    expect(slp_role).to eq("member")
  end

  # The post-claim shape (issue #166): the SLP created the team and so can
  # manage it, while the parent is now the communicator's owner.
  context "after the SLP→parent claim hand-off" do
    let!(:handoff_account) do
      create(:child_account, user: parent, owner: parent, status: ChildAccount::ACTIVE)
    end
    let!(:handoff_team) do
      t = handoff_account.ensure_team!(creator: slp)
      t.upsert_member!(parent, "admin")
      t.upsert_member!(slp, "supervisor")
      t
    end

    it "refuses the managing SLP changing the communicator owner's row" do
      patch "/api/teams/#{handoff_team.id}/member_role",
            params: { user_id: parent.id, role: "restricted" },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("cannot_change_owner_role")
      expect(TeamUser.find_by(team: handoff_team, user: parent).reload.role).to eq("admin")
    end

    it "lets the parent owner reduce the departing SLP, creator or not" do
      patch "/api/teams/#{handoff_team.id}/member_role",
            params: { user_id: slp.id, role: "restricted" },
            headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      expect(TeamUser.find_by(team: handoff_team, user: slp).reload.role).to eq("restricted")
    end
  end

  it "404s for a user who is not on the team" do
    patch "/api/teams/#{team.id}/member_role",
          params: { user_id: stranger.id, role: "supervisor" },
          headers: auth_headers(parent)

    expect(response).to have_http_status(:not_found)
  end
end
