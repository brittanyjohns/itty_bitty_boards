# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260711120000_remap_stray_admin_team_users_to_supervisor.rb")

# Team permissions overhaul (Phase 0-3). Locks down authorization on every
# mutating API::Teams action and enforces the 4-tier role model
# (admin/supervisor/member/restricted). Role x action matrix mirrors
# .claude-notes/team-permissions-overhaul-handoff.md.
RSpec.describe "API::Teams permissions", type: :request do
  # team_creator == the "team owner (admin)" column: created the team.
  # account_owner owns the communicator attached to the team.
  let(:team_creator) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:account_owner) { create(:user, created_at: 2.months.ago) }
  let(:supervisor)    { create(:user, created_at: 2.months.ago) }
  let(:member)        { create(:user, created_at: 2.months.ago) }
  let(:restricted)    { create(:user, created_at: 2.months.ago) }
  let(:stranger)      { create(:user, created_at: 2.months.ago) }
  let(:sysadmin)      { create(:admin_user) }

  let!(:communicator) do
    create(:child_account, user: account_owner, owner: account_owner,
                           status: ChildAccount::ACTIVE)
  end

  let!(:team) do
    t = Team.create!(name: "Care Team", created_by: team_creator)
    TeamAccount.create!(team: t, account: communicator)
    t.upsert_member!(team_creator, "admin")
    t.upsert_member!(account_owner, "member") # owner-pinned via account ownership
    t.upsert_member!(supervisor, "supervisor")
    t.upsert_member!(member, "member")
    t.upsert_member!(restricted, "restricted")
    t
  end

  let(:board) { create(:board, user: team_creator) }

  describe "GET /api/teams/:id (show)" do
    it "lets every member (incl. restricted) and managers view the team" do
      [restricted, member, supervisor, team_creator, account_owner, sysadmin].each do |u|
        get "/api/teams/#{team.id}", headers: auth_headers(u)
        expect(response).to have_http_status(:ok), "expected #{u.email} to view"
      end
    end

    it "blocks a stranger who isn't on the team (403)" do
      get "/api/teams/#{team.id}", headers: auth_headers(stranger)
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_a_team_member")
    end

    it "exposes current_user_role for the viewer" do
      get "/api/teams/#{team.id}", headers: auth_headers(supervisor)
      expect(JSON.parse(response.body)["current_user_role"]).to eq("supervisor")

      get "/api/teams/#{team.id}", headers: auth_headers(restricted)
      expect(JSON.parse(response.body)["current_user_role"]).to eq("restricted")
    end
  end

  describe "GET /api/teams (index)" do
    it "includes current_user_role and only the caller's teams" do
      get "/api/teams", headers: auth_headers(member)
      body = JSON.parse(response.body)
      mine = body.find { |t| t["id"] == team.id }
      expect(mine).to be_present
      expect(mine["current_user_role"]).to eq("member")
    end
  end

  describe "PATCH /api/teams/:id (update)" do
    it "lets managers rename the team" do
      [team_creator, account_owner, sysadmin].each do |u|
        patch "/api/teams/#{team.id}",
              params: { team: { name: "Renamed by #{u.id}" } },
              headers: auth_headers(u)
        expect(response).to have_http_status(:ok), "expected #{u.email} to rename"
      end
    end

    it "blocks non-managers (supervisor/member/restricted/stranger) with 403" do
      [supervisor, member, restricted, stranger].each do |u|
        patch "/api/teams/#{team.id}",
              params: { team: { name: "Nope" } },
              headers: auth_headers(u)
        expect(response).to have_http_status(:forbidden), "expected #{u.email} blocked"
        expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
      end
    end
  end

  describe "DELETE /api/teams/:id (destroy)" do
    it "lets a manager delete the team" do
      expect {
        delete "/api/teams/#{team.id}", headers: auth_headers(team_creator)
      }.to change { Team.where(id: team.id).count }.from(1).to(0)
      expect(response).to have_http_status(:ok)
    end

    it "blocks a supervisor from deleting (403)" do
      expect {
        delete "/api/teams/#{team.id}", headers: auth_headers(supervisor)
      }.not_to change { Team.where(id: team.id).count }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/teams/:id/invite" do
    def invite(user, email:, role:)
      post "/api/teams/#{team.id}/invite",
           params: { team_user: { email: email, role: role } },
           headers: auth_headers(user)
    end

    it "lets a manager invite a new supervisor (201)" do
      invite(team_creator, email: "newslp@example.com", role: "supervisor")
      expect(response).to have_http_status(:created)
      invited = User.find_by(email: "newslp@example.com")
      expect(TeamUser.find_by(team: team, user: invited).role).to eq("supervisor")
    end

    it "persists a restricted (Read-Only) invite as restricted, not member" do
      invite(account_owner, email: "readonly@example.com", role: "restricted")
      expect(response).to have_http_status(:created)
      invited = User.find_by(email: "readonly@example.com")
      expect(TeamUser.find_by(team: team, user: invited).role).to eq("restricted")
    end

    it "rejects a junk role with 422 (no silent coercion)" do
      invite(team_creator, email: "junk@example.com", role: "wizard")
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_role")
      expect(User.find_by(email: "junk@example.com")).to be_nil
    end

    it "rejects an explicit admin invite with 422 (admin is owner-only)" do
      invite(team_creator, email: "wannabe@example.com", role: "admin")
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_role")
    end

    it "blocks non-managers from inviting (403)" do
      [supervisor, member, restricted, stranger].each do |u|
        invite(u, email: "x#{u.id}@example.com", role: "member")
        expect(response).to have_http_status(:forbidden), "expected #{u.email} blocked"
        expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
      end
    end
  end

  describe "DELETE /api/teams/:id/remove_member" do
    it "lets a manager remove a plain member" do
      expect {
        delete "/api/teams/#{team.id}/remove_member",
               params: { email: member.email },
               headers: auth_headers(team_creator)
      }.to change { TeamUser.where(team: team, user: member).count }.from(1).to(0)
      expect(response).to have_http_status(:ok)
    end

    it "blocks a supervisor from removing a member (403)" do
      expect {
        delete "/api/teams/#{team.id}/remove_member",
               params: { email: member.email },
               headers: auth_headers(supervisor)
      }.not_to change { TeamUser.where(team: team).count }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
    end
  end

  describe "POST /api/teams/:id/create_board (team library)" do
    def create_board(user, board_record)
      post "/api/teams/#{team.id}/create_board",
           params: { board_id: board_record.id },
           headers: auth_headers(user)
    end

    it "lets library writers (member/supervisor/admin/account owner/sysadmin) add a board" do
      # Distinct board per writer — `add_board!` keys idempotency on the
      # adder, so reusing one board across users isn't a real-world flow.
      [member, supervisor, team_creator, account_owner, sysadmin].each do |u|
        create_board(u, create(:board, user: team_creator))
        expect(response).to have_http_status(:ok), "expected #{u.email} to add a board"
      end
    end

    it "blocks a restricted (Read-Only) member from writing the library (403)" do
      expect {
        create_board(restricted, board)
      }.not_to change { team.team_boards.count }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_a_team_member")
    end

    it "blocks a stranger (403)" do
      create_board(stranger, board)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/teams/:id/remove_board" do
    before { team.add_board!(board, team_creator.id) }

    def remove_board(user)
      delete "/api/teams/#{team.id}/remove_board",
             params: { board_id: board.id },
             headers: auth_headers(user)
    end

    it "lets a supervisor and managers remove a board" do
      [supervisor, team_creator, account_owner, sysadmin].each do |u|
        team.add_board!(board, team_creator.id) # re-add between removals
        remove_board(u)
        expect(response).to have_http_status(:ok), "expected #{u.email} to remove a board"
      end
    end

    it "blocks a plain member from removing a board (403)" do
      expect {
        remove_board(member)
      }.not_to change { team.team_boards.count }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
    end

    it "blocks restricted and strangers (403)" do
      [restricted, stranger].each do |u|
        remove_board(u)
        expect(response).to have_http_status(:forbidden), "expected #{u.email} blocked"
      end
    end
  end

  describe "PATCH /api/teams/:id/accept_invite_patch" do
    it "returns 404 (not 500) when the caller has no membership on the team" do
      no_membership = create(:user, created_at: 2.months.ago)
      patch "/api/teams/#{team.id}/accept_invite_patch",
            params: { team_user: { email: no_membership.email } },
            headers: auth_headers(no_membership)
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("not_a_team_member")
    end

    it "returns 404 when the email matches no user at all" do
      patch "/api/teams/#{team.id}/accept_invite_patch",
            params: { team_user: { email: "ghost@example.com" } },
            headers: auth_headers(member)
      expect(response).to have_http_status(:not_found)
    end

    it "accepts the invitation for a real pending member" do
      patch "/api/teams/#{team.id}/accept_invite_patch",
            params: { team_user: { email: supervisor.email } },
            headers: auth_headers(supervisor)
      expect(response).to have_http_status(:ok)
      expect(TeamUser.find_by(team: team, user: supervisor).invitation_accepted_at).to be_present
    end
  end

  describe "POST /api/teams (create) — owner-side Pro gate" do
    it "lets a paid owner create a team" do
      pro = create(:user, plan_type: "pro", created_at: 2.months.ago)
      expect {
        post "/api/teams", params: { team: { name: "New Team" } }, headers: auth_headers(pro)
      }.to change { Team.count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "lets a brand-new free-trial owner create a team" do
      trial = create(:user, plan_type: "free", created_at: 1.day.ago)
      post "/api/teams", params: { team: { name: "Trial Team" } }, headers: auth_headers(trial)
      expect(response).to have_http_status(:created)
    end

    it "blocks a free, past-trial owner with 403 pro_required" do
      free = create(:user, plan_type: "free", created_at: 1.year.ago)
      expect {
        post "/api/teams", params: { team: { name: "Nope" } }, headers: auth_headers(free)
      }.not_to change { Team.count }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("pro_required")
    end
  end

  describe "role remap migration" do
    it "remaps stray admins to supervisor, keeping creator/owner admins" do
      creator = create(:user, plan_type: "pro", created_at: 2.months.ago)
      owner   = create(:user, created_at: 2.months.ago)
      stray   = create(:user, created_at: 2.months.ago)
      comm = create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
      t = Team.create!(name: "Remap Team", created_by: creator)
      TeamAccount.create!(team: t, account: comm)
      creator_tu = t.upsert_member!(creator, "admin")
      owner_tu   = t.upsert_member!(owner, "admin")
      stray_tu   = t.upsert_member!(stray, "admin")

      ActiveRecord::Migration.suppress_messages do
        RemapStrayAdminTeamUsersToSupervisor.new.up
      end

      expect(creator_tu.reload.role).to eq("admin")
      expect(owner_tu.reload.role).to eq("admin")
      expect(stray_tu.reload.role).to eq("supervisor")
    end
  end
end
