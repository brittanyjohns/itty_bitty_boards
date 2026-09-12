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
    # Everyone but the creator arrived by invitation, so they start unaccepted
    # — the shape `TeamsController#invite` writes (`accepted: false`, #923).
    # The accept-invite examples below depend on it.
    t.upsert_member!(account_owner, "member", accepted: false) # owner-pinned via account ownership
    t.upsert_member!(supervisor, "supervisor", accepted: false)
    t.upsert_member!(member, "member", accepted: false)
    t.upsert_member!(restricted, "restricted", accepted: false)
    t
  end

  let(:board) { create(:board, user: team_creator) }

  # Inviting a NEW user routes through User.invite_new_user_to_team! ->
  # create_stripe_customer -> Stripe::Customer.create. Stub it so specs never
  # make a live Stripe/network call (CI has no creds). Returns a hash-like the
  # caller indexes with ["id"].
  before do
    allow(Stripe::Customer).to receive(:create).and_return({ "id" => "cus_test_stub" })
  end

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

    # #923 — `upsert_member!` stamps `invitation_accepted_at` by default;
    # invite is the one caller that must not, or the roster would report every
    # unopened invitation as somebody who has already turned up.
    it "does not mark a fresh invitee as joined" do
      invite(team_creator, email: "notyet@example.com", role: "supervisor")

      invited = User.find_by(email: "notyet@example.com")
      tu = TeamUser.find_by(team: team, user: invited)
      expect(tu.invitation_accepted_at).to be_nil
      expect(tu).not_to be_joined
    end

    it "does not un-join an existing member on a re-invite" do
      tu = TeamUser.find_by(team: team, user: supervisor)
      tu.accept_invitation!
      stamped = tu.reload.invitation_accepted_at

      invite(team_creator, email: supervisor.email, role: "supervisor")

      expect(response).to have_http_status(:created)
      expect(tu.reload.invitation_accepted_at).to eq(stamped)
    end

    it "reports the team creator as joined on the payload it returns" do
      invite(team_creator, email: "newslp2@example.com", role: "supervisor")

      creator_row = JSON.parse(response.body)["members"]
        .find { |m| m["user_id"] == team_creator.id }
      expect(creator_row["joined"]).to be true
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

    # #915: the mailer picks its link shape from `raw_invitation_token`, which
    # devise_invitable populates only on the call that mints it. Without a
    # re-issue, every invite after the first sent a passwordless account to
    # `/accept-invite`, where it can neither sign up (`email_taken` — its own
    # row holds the address) nor sign in (there is no password). So the invite
    # path worked exactly once per address. The link SHAPE that follows from
    # the token is asserted in `spec/mailers/base_mailer_spec.rb`.
    describe "inviting an address that has no account yet" do
      it "mints a fresh invitation token on a SECOND invite" do
        invite(team_creator, email: "brand.new@example.com", role: "member")
        invited = User.find_by(email: "brand.new@example.com")
        expect(invited.invited_to_sign_up?).to be(true)

        expect {
          invite(team_creator, email: "brand.new@example.com", role: "supervisor")
        }.to change { invited.reload.invitation_token }
      end

      it "leaves the role change from the second invite in place" do
        invite(team_creator, email: "brand.new@example.com", role: "member")
        invite(team_creator, email: "brand.new@example.com", role: "supervisor")

        invited = User.find_by(email: "brand.new@example.com")
        expect(TeamUser.find_by(team: team, user: invited).role).to eq("supervisor")
      end

      it "does not rotate anything for an address that already has a password" do
        # A real account signs in and accepts, so `/accept-invite` is correct
        # for them and their invitation state must not be touched.
        expect(stranger.invited_to_sign_up?).to be(false)

        expect {
          invite(team_creator, email: stranger.email, role: "member")
        }.not_to change { stranger.reload.invitation_token }
      end

      it "never fails the invite when the re-issue cannot run" do
        # Degraded, not broken: without a fresh token the mailer falls back to
        # the `/accept-invite` link, where the preview's `needs_password` still
        # explains itself. Refusing the invite would be strictly worse.
        invite(team_creator, email: "brand.new@example.com", role: "member")
        allow_any_instance_of(User).to receive(:invite!).and_raise("boom")

        invite(team_creator, email: "brand.new@example.com", role: "supervisor")

        expect(response).to have_http_status(:created)
      end
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

    it "lets library writers (member/supervisor/admin/account owner/sysadmin) add a board they own" do
      # Each writer shares their OWN board — that is the real-world flow, and
      # sharing a board makes it readable to the whole team, so `create_board`
      # now refuses a board the caller has no claim to.
      [member, supervisor, team_creator, account_owner].each do |u|
        create_board(u, create(:board, user: u))
        expect(response).to have_http_status(:ok), "expected #{u.email} to add a board"
      end

      # A sysadmin may share anything, including somebody else's board.
      create_board(sysadmin, create(:board, user: team_creator))
      expect(response).to have_http_status(:ok)
    end

    it "blocks a library writer sharing a board they have no claim to (403)" do
      stranger_board = create(:board, user: create(:user), published: false)

      expect {
        create_board(supervisor, stranger_board)
      }.not_to change { team.team_boards.count }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_board_owner")
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

  describe "GET /api/teams/:id/accept_invite (public preview)" do
    it "returns the team/inviter/role payload for a valid token (no auth required)" do
      get "/api/teams/#{team.id}/accept_invite", params: { token: supervisor.uuid }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["team_name"]).to eq(team.name)
      expect(body["invited_by_name"]).to eq(team_creator.display_name)
      expect(body["role"]).to eq("supervisor")
      # Email is masked, not leaked in full.
      expect(body["email"]).to end_with("@#{supervisor.email.split('@').last}")
      expect(body["email"]).not_to eq(supervisor.email)
    end

    it "returns 404 with a structured error for a wrong/unknown token" do
      get "/api/teams/#{team.id}/accept_invite", params: { token: SecureRandom.uuid }
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("invite_not_found")
    end

    it "returns 404 when the token belongs to a user with no membership on this team" do
      get "/api/teams/#{team.id}/accept_invite", params: { token: stranger.uuid }
      expect(response).to have_http_status(:not_found)
    end

    # Both signed-out doors on the accept screen are closed to an invitee who
    # has never set a password: sign-up answers `email_taken` (their own
    # invited row holds the address) and sign-in has no password to accept.
    # The frontend offers a password reset instead, on this flag (#915).
    it "reports needs_password for an invitee who has never set one" do
      invited = User.invite!(email: "brand.new@example.com") { |u| u.skip_invitation = true }
      team.upsert_member!(invited, "member", accepted: false)

      get "/api/teams/#{team.id}/accept_invite", params: { token: invited.uuid }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["needs_password"]).to be(true)
    end

    it "does not report needs_password for a member with a real account" do
      get "/api/teams/#{team.id}/accept_invite", params: { token: supervisor.uuid }

      expect(JSON.parse(response.body)["needs_password"]).to be(false)
    end
  end

  describe "PATCH /api/teams/:id/accept_invite_patch" do
    it "accepts the invitation for the invitee with a valid token" do
      patch "/api/teams/#{team.id}/accept_invite_patch",
            params: { token: supervisor.uuid },
            headers: auth_headers(supervisor)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(team.id)
      expect(TeamUser.find_by(team: team, user: supervisor).invitation_accepted_at).to be_present
    end

    it "ignores a spoofed email param — identity comes from current_user only" do
      patch "/api/teams/#{team.id}/accept_invite_patch",
            params: { token: supervisor.uuid, email: member.email,
                      team_user: { email: member.email } },
            headers: auth_headers(supervisor)
      expect(response).to have_http_status(:ok)
      # Supervisor's own membership was accepted; the member's was untouched.
      expect(TeamUser.find_by(team: team, user: supervisor).invitation_accepted_at).to be_present
      expect(TeamUser.find_by(team: team, user: member).invitation_accepted_at).to be_nil
    end

    it "returns 403 when signed in as a DIFFERENT user than the invitee" do
      # member is on the team but follows the supervisor's invite link.
      patch "/api/teams/#{team.id}/accept_invite_patch",
            params: { token: supervisor.uuid },
            headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("invite_token_mismatch")
      expect(TeamUser.find_by(team: team, user: member).invitation_accepted_at).to be_nil
    end

    it "returns 404 (not 500) when the caller has no membership on the team" do
      no_membership = create(:user, created_at: 2.months.ago)
      patch "/api/teams/#{team.id}/accept_invite_patch",
            params: { token: no_membership.uuid },
            headers: auth_headers(no_membership)
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("not_a_team_member")
    end

    # #914 — nothing in this controller told the owner anything, ever.
    describe "notifying the team's owner" do
      def accept_as(user)
        patch "/api/teams/#{team.id}/accept_invite_patch",
              params: { token: user.uuid },
              headers: auth_headers(user)
      end

      it "emails the team's creator when someone joins" do
        expect {
          accept_as(supervisor)
        }.to have_enqueued_mail(BaseMailer, :team_member_joined_email)

        expect(response).to have_http_status(:ok)
      end

      it "only mails on the transition, not on a repeat accept" do
        accept_as(supervisor)

        expect {
          accept_as(supervisor)
        }.not_to have_enqueued_mail(BaseMailer, :team_member_joined_email)

        expect(response).to have_http_status(:ok)
      end

      it "does not mail when the accept is refused" do
        expect {
          patch "/api/teams/#{team.id}/accept_invite_patch",
                params: { token: supervisor.uuid },
                headers: auth_headers(member)
        }.not_to have_enqueued_mail(BaseMailer, :team_member_joined_email)

        expect(response).to have_http_status(:forbidden)
      end

      # The acceptance is already written by the time the mail is attempted;
      # a delivery error must not turn a successful join into a 500.
      it "still accepts the invitation when the mail cannot be enqueued" do
        allow(BaseMailer).to receive(:team_member_joined_email).and_raise(StandardError, "boom")

        accept_as(supervisor)

        expect(response).to have_http_status(:ok)
        expect(TeamUser.find_by(team: team, user: supervisor).invitation_accepted_at).to be_present
      end
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
