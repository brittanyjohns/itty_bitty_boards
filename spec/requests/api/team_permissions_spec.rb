# frozen_string_literal: true

require "rails_helper"

# Issue #166 — owner-protection rules on team membership endpoints.
# After the SLP→parent claim hand-off, the SLP remains on the team as a
# supervisor while the parent is the new owner. These specs lock in the
# rule that the owner cannot be removed or demoted by anyone other than
# themselves (or a system admin).
RSpec.describe "API::Teams owner protection", type: :request do
  let(:slp)    { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_slp_stub") }
  let(:parent) { create(:user, created_at: 2.months.ago, stripe_customer_id: "cus_parent_stub") }

  # Mirror the post-claim shape: the parent is the owner of the account,
  # the SLP is the previous owner who stays on the team as a supervisor.
  let!(:account) do
    create(:child_account,
           user: parent,
           owner: parent,
           status: ChildAccount::ACTIVE,
           passcode: "ownerpw1")
  end
  let!(:team) do
    t = account.ensure_team!(creator: slp)
    t.add_member!(parent, "admin")
    t.add_member!(slp, "supervisor")
    t
  end

  describe "DELETE /api/teams/:id/remove_member" do
    it "blocks an SLP supervisor from removing the parent owner (403)" do
      expect {
        delete "/api/teams/#{team.id}/remove_member",
               params: { email: parent.email },
               headers: auth_headers(slp)
      }.not_to change { TeamUser.where(team: team).count }

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("cannot_remove_owner")
    end

    it "lets the parent owner remove the SLP supervisor" do
      expect {
        delete "/api/teams/#{team.id}/remove_member",
               params: { email: slp.email },
               headers: auth_headers(parent)
      }.to change { TeamUser.where(team: team, user: slp).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
    end

    it "lets the owner remove themselves (single allowed self-action)" do
      expect {
        delete "/api/teams/#{team.id}/remove_member",
               params: { email: parent.email },
               headers: auth_headers(parent)
      }.to change { TeamUser.where(team: team, user: parent).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
    end

    it "lets a system admin remove the owner (escape hatch)" do
      admin = create(:admin_user)
      expect {
        delete "/api/teams/#{team.id}/remove_member",
               params: { email: parent.email },
               headers: auth_headers(admin)
      }.to change { TeamUser.where(team: team, user: parent).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/teams/:id/invite (role change path)" do
    it "blocks an SLP supervisor from demoting the parent owner (403)" do
      post "/api/teams/#{team.id}/invite",
           params: { team_user: { email: parent.email, role: "member" } },
           headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("cannot_change_owner_role")

      expect(TeamUser.find_by(team: team, user: parent).role).to eq("admin")
    end

    it "blocks an SLP supervisor from changing the owner's role to admin (a no-op for owner, still rejected)" do
      # Start parent at "member" (legacy data) and confirm SLP cannot
      # touch the owner row even when the change would be benign.
      TeamUser.find_by(team: team, user: parent).update!(role: "member")

      post "/api/teams/#{team.id}/invite",
           params: { team_user: { email: parent.email, role: "admin" } },
           headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("cannot_change_owner_role")
    end

    it "blocks an SLP supervisor from self-promoting to admin (403)" do
      post "/api/teams/#{team.id}/invite",
           params: { team_user: { email: slp.email, role: "admin" } },
           headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("cannot_self_promote")

      expect(TeamUser.find_by(team: team, user: slp).role).to eq("supervisor")
    end

    it "lets the parent owner change the SLP's role" do
      post "/api/teams/#{team.id}/invite",
           params: { team_user: { email: slp.email, role: "member" } },
           headers: auth_headers(parent)

      expect(response).to have_http_status(:created)
      expect(TeamUser.find_by(team: team, user: slp).role).to eq("member")
    end
  end

  describe "GET /api/teams/:id (api_view)" do
    it "exposes account_owner_ids and per-member is_account_owner" do
      get "/api/teams/#{team.id}", headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["account_owner_ids"]).to eq([parent.id])

      parent_member = body["members"].find { |m| m["user_id"] == parent.id }
      slp_member    = body["members"].find { |m| m["user_id"] == slp.id }
      expect(parent_member["is_account_owner"]).to eq(true)
      expect(slp_member["is_account_owner"]).to eq(false)
    end
  end
end
