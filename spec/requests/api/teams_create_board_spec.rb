# frozen_string_literal: true

require "rails_helper"

# Issue #216 — `POST /api/teams/:id/create_board` now requires the
# caller to be on the team (any role) or a system admin. Closes the
# gap where any signed-in user could write to any team's `team_boards`.
RSpec.describe "API::Teams#create_board membership gate", type: :request do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
  end
  let!(:team) do
    # Mirror the production shape: controllers always add the creator
    # as the admin team_user when ensuring a team for a child_account.
    t = account.ensure_team!(creator: owner)
    t.add_member!(owner, "admin")
    t
  end
  let(:board) { create(:board, user: owner) }

  def post_create_board(user)
    post "/api/teams/#{team.id}/create_board",
         params: { board_id: board.id },
         headers: auth_headers(user)
  end

  it "lets the team owner (admin) add a board" do
    post_create_board(owner)
    expect(response).to have_http_status(:ok)
  end

  it "lets a supervisor add a board" do
    user = create(:user, created_at: 2.months.ago)
    team.add_member!(user, "supervisor")
    post_create_board(user)
    expect(response).to have_http_status(:ok)
  end

  it "lets a plain member add a board to the team library" do
    user = create(:user, created_at: 2.months.ago)
    team.add_member!(user, "member")
    post_create_board(user)
    expect(response).to have_http_status(:ok)
  end

  it "rejects a stranger who isn't on the team (403)" do
    stranger = create(:user, created_at: 2.months.ago)
    expect {
      post_create_board(stranger)
    }.not_to change { team.team_boards.count }
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("not_a_team_member")
  end

  it "lets a system admin add a board even when not on the team" do
    sys_admin = create(:admin_user)
    post_create_board(sys_admin)
    expect(response).to have_http_status(:ok)
  end
end
