# frozen_string_literal: true

require "rails_helper"

# Teams API hardening. Every example here pins a hole that was live in
# production, not a preference:
#
#   * sharing a board with a team makes it READABLE by every member
#     (`Board#viewable_by?` ends in `team_users.exists?`, reached through
#     `has_many :team_users, through: :teams`), and `create_board` took any
#     board id at all — board ids are sequential;
#   * `reset_password_invite` let the INVITEE set their own `TeamUser.role`
#     from a request param, and `TeamUser::ROLES` contains "admin";
#   * `team_accounts#update`/`#destroy` authorized on the Pundit scope only,
#     which admits every member at every role — and detaching the last
#     communicator destroys the whole team.
RSpec.describe "Teams API hardening", type: :request do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
  end
  let!(:team) do
    t = account.ensure_team!(creator: owner)
    t.upsert_member!(owner, "admin")
    t
  end

  describe "POST /api/teams/:id/create_board — board entitlement" do
    let(:supervisor) { create(:user, created_at: 2.months.ago) }

    before { team.upsert_member!(supervisor, "supervisor") }

    def share(user, board)
      post "/api/teams/#{team.id}/create_board",
           params: { board_id: board.id },
           headers: auth_headers(user)
    end

    it "refuses a stranger's private board, and shares nothing" do
      stranger_board = create(:board, user: create(:user), published: false)

      expect { share(supervisor, stranger_board) }
        .not_to change { team.team_boards.count }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_board_owner")
    end

    it "does not make a stranger's private board readable to the team" do
      stranger_board = create(:board, user: create(:user), published: false)
      share(supervisor, stranger_board)

      expect(stranger_board.reload.viewable_by?(supervisor)).to be false
    end

    it "allows a published board (it is already public to everyone)" do
      public_board = create(:board, user: create(:user), published: true)
      share(supervisor, public_board)
      expect(response).to have_http_status(:ok)
    end

    it "allows a board already on a communicator's dashboard on this team" do
      family_board = create(:board, user: owner, published: false)
      account.child_boards.create!(board: family_board, created_by_id: owner.id)

      share(supervisor, family_board)
      expect(response).to have_http_status(:ok)
    end

    it "refuses an unknown board id with the same generic error" do
      post "/api/teams/#{team.id}/create_board",
           params: { board_id: 0 },
           headers: auth_headers(supervisor)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_board_owner")
    end

    # Regression: `add_board!` used to look an existing row up by
    # (board, created_by_id), so a second sharer got nil back and the
    # controller's `.save` raised NoMethodError.
    it "is idempotent across two different sharers and never 500s" do
      shared = create(:board, user: owner)
      share(owner, shared)
      expect(response).to have_http_status(:ok)

      account.child_boards.create!(board: shared, created_by_id: owner.id)
      expect { share(supervisor, shared) }.not_to change { team.team_boards.count }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "DELETE /api/teams/:id/remove_board" do
    it "lets the board's owner un-share it even as a plain member" do
      sharer = create(:user, created_at: 2.months.ago)
      team.upsert_member!(sharer, "member")
      board = create(:board, user: sharer)
      team.add_board!(board, sharer.id)

      expect {
        delete "/api/teams/#{team.id}/remove_board",
               params: { board_id: board.id },
               headers: auth_headers(sharer)
      }.to change { team.team_boards.count }.by(-1)

      expect(response).to have_http_status(:ok)
    end

    it "still refuses a member who does not own the board" do
      member = create(:user, created_at: 2.months.ago)
      team.upsert_member!(member, "member")
      board = create(:board, user: owner)
      team.add_board!(board, owner.id)

      expect {
        delete "/api/teams/#{team.id}/remove_board",
               params: { board_id: board.id },
               headers: auth_headers(member)
      }.not_to change { team.team_boards.count }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/reset_password_invite — role escalation" do
    it "ignores a role param and leaves the invited role untouched" do
      invitee = User.invite!(email: "invited-hardening@example.com") { |u| u.skip_invitation = true }
      team.upsert_member!(invitee, "member")
      raw_token = invitee.raw_invitation_token

      patch "/api/v1/reset_password_invite",
            params: {
              invitation_token: raw_token,
              password: "sup3rsecret!",
              password_confirmation: "sup3rsecret!",
              role: "admin",
            }

      expect(TeamUser.find_by(user_id: invitee.id, team_id: team.id).role).to eq("member")
    end
  end

  describe "team_accounts management" do
    let(:member) { create(:user, created_at: 2.months.ago) }
    let!(:team_account) { TeamAccount.find_by(team: team, account: account) }

    before { team.upsert_member!(member, "restricted") }

    it "refuses a read-only member deactivating a communicator" do
      patch "/api/team_accounts/#{team_account.id}",
            params: { team_account: { active: false } },
            headers: auth_headers(member)

      expect(response).to have_http_status(:forbidden)
      expect(team_account.reload.active).to be true
    end

    # Detaching the last communicator fires TeamAccount#before_destroy, which
    # destroys the whole team and cascades every membership.
    it "refuses a read-only member detaching the last communicator" do
      expect {
        delete "/api/team_accounts/#{team_account.id}", headers: auth_headers(member)
      }.not_to change { Team.count }

      expect(response).to have_http_status(:forbidden)
    end

    it "lets the communicator's owner detach it" do
      delete "/api/team_accounts/#{team_account.id}", headers: auth_headers(owner)
      expect(response).to have_http_status(:success)
    end
  end

  # `PUT /api/boards/:id/add_to_team` was in NO before_action list — any
  # signed-in user could push any board id onto any team id. The frontend's
  # `addToTeam`/`removeFromTeam` are exported and never imported, so the action
  # and both routes are gone rather than gated. Unmatched paths fall to the
  # catch-all (`match "*path" => "error#not_found"`), hence a 404 rather than a
  # raised RoutingError.
  describe "removed routes" do
    it "no longer routes boards#add_to_team" do
      board = create(:board, user: owner)

      expect {
        put "/api/boards/#{board.id}/add_to_team",
            params: { team_id: team.id },
            headers: auth_headers(owner)
      }.not_to change { team.team_boards.count }

      expect(response).to have_http_status(:not_found)
    end

    it "does not route the actionless teams#add_board" do
      post "/api/teams/#{team.id}/add_board",
           params: { board_id: create(:board, user: owner).id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:not_found)
    end
  end
end
