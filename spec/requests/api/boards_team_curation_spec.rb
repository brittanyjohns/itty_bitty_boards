# frozen_string_literal: true

require "rails_helper"

# Issue #889, Part 1 — the write gate and the `can_edit` flag are one answer.
#
# `check_board_view_edit_permissions` (authorization) and `Board#can_edit_for`
# (the flag the editor gates its affordances on) have to agree, or a board the
# UI offers to edit 403s on save. These specs drive both through HTTP.
RSpec.describe "API::Boards team curation", type: :request do
  let(:parent)  { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:slp)     { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:support) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  let!(:account) do
    create(:child_account, user: parent, owner: parent, status: ChildAccount::ACTIVE)
  end

  let!(:board)      { create(:board, user: parent, name: "Eli's core words") }
  let!(:sub_board)  { create(:board, user: parent, name: "Food") }
  let!(:folder_tile) do
    create(:board_image, board: board, predictive_board_id: sub_board.id)
  end
  let!(:child_board) { create(:child_board, board: board, child_account: account) }

  let!(:team) do
    t = account.ensure_team!(creator: parent)
    t.upsert_member!(parent, "admin")
    t.upsert_member!(slp, "supervisor")
    t.upsert_member!(support, "member")
    t
  end

  describe "PUT /api/boards/:id" do
    it "lets a supervisor rename a board on a communicator they curate" do
      put "/api/boards/#{board.id}",
          params: { board: { description: "Updated by the SLP" } },
          headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      expect(board.reload.description).to eq("Updated by the SLP")
    end

    it "reaches a folder page of that board, which is attached to nothing" do
      put "/api/boards/#{sub_board.id}",
          params: { board: { description: "Fringe page edit" } },
          headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      expect(sub_board.reload.description).to eq("Fringe page edit")
    end

    # A Support member may READ this board — since #887 the namesake team is
    # seeded with the communicator's dashboard boards, and a `team_boards` row
    # is a read grant — so the refusal is the see-but-don't-own 403, not a 404.
    # The generic 404 is still what a caller who can't see the board gets; the
    # next example covers it.
    it "refuses a Support member and changes nothing" do
      put "/api/boards/#{board.id}",
          params: { board: { description: "Support tried" } },
          headers: auth_headers(support)

      expect(response).to have_http_status(:forbidden)
      expect(board.reload.description).not_to eq("Support tried")
    end

    it "refuses a board the family never shared" do
      private_board = create(:board, user: parent)

      put "/api/boards/#{private_board.id}",
          params: { board: { description: "Should not land" } },
          headers: auth_headers(slp)

      expect(response).to have_http_status(:not_found)
      expect(private_board.reload.description).not_to eq("Should not land")
    end
  end

  describe "GET /api/boards/:id" do
    it "reports can_edit: true to the supervisor, so the flag matches the gate" do
      get "/api/boards/#{board.id}", headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["can_edit"]).to be true
    end

    it "reports can_edit: false on a team-library board the supervisor doesn't curate" do
      library_board = create(:board, user: parent)
      team.add_board!(library_board, parent.id)

      get "/api/boards/#{library_board.id}", headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["can_edit"]).to be false
    end
  end

  # Issue #923 (finding 2) — Support and Read-Only members could see the child
  # and none of the child's boards. Reading is now reachability-based for every
  # team role, as curating already was.
  describe "GET /api/boards/:id — reading by a non-curate role" do
    let!(:restricted) { create(:user, created_at: 2.months.ago) }
    let!(:stranger)   { create(:user, created_at: 2.months.ago) }

    before { team.upsert_member!(restricted, "restricted") }

    it "lets a Support (member) invitee read a dashboard-attached board" do
      get "/api/boards/#{board.id}", headers: auth_headers(support)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["can_edit"]).to be false
    end

    it "lets a Read-Only (restricted) invitee read it" do
      get "/api/boards/#{board.id}", headers: auth_headers(restricted)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["can_edit"]).to be false
    end

    it "reaches a folder page that carries no child_boards row" do
      get "/api/boards/#{sub_board.id}", headers: auth_headers(support)
      expect(response).to have_http_status(:ok)

      get "/api/boards/#{sub_board.id}", headers: auth_headers(restricted)
      expect(response).to have_http_status(:ok)
    end

    # The production state #923 was filed against: the board was attached
    # before `ChildBoard#register_on_communicator_team` existed, so no
    # `team_boards` row was ever written.
    it "reads a board that predates team registration" do
      team.team_boards.destroy_all

      get "/api/boards/#{board.id}", headers: auth_headers(support)
      expect(response).to have_http_status(:ok)
    end

    it "still 404s a non-member — the generic refusal is unchanged" do
      get "/api/boards/#{board.id}", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)

      get "/api/boards/#{sub_board.id}", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)
    end

    it "still 404s a board of the family's that is on no shared dashboard" do
      private_board = create(:board, user: parent)

      get "/api/boards/#{private_board.id}", headers: auth_headers(support)
      expect(response).to have_http_status(:not_found)
    end

    it "does not let a reader write" do
      put "/api/boards/#{board.id}",
          params: { board: { description: "Read-only tried" } },
          headers: auth_headers(restricted)

      expect(response).to have_http_status(:forbidden)
      expect(board.reload.description).not_to eq("Read-only tried")
    end
  end

  describe "DELETE /api/boards/:id" do
    it "still refuses a supervisor — the family keeps the board" do
      expect {
        delete "/api/boards/#{board.id}", headers: auth_headers(slp)
      }.not_to change { Board.where(id: board.id).count }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
