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

    # A caller who can't SEE the board gets the same generic 404 that #show
    # gives, never 403 — board ids are sequential and a board name routinely
    # carries a child's first name.
    it "refuses a Support member and changes nothing" do
      put "/api/boards/#{board.id}",
          params: { board: { description: "Support tried" } },
          headers: auth_headers(support)

      expect(response).to have_http_status(:not_found)
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

  describe "DELETE /api/boards/:id" do
    it "still refuses a supervisor — the family keeps the board" do
      expect {
        delete "/api/boards/#{board.id}", headers: auth_headers(slp)
      }.not_to change { Board.where(id: board.id).count }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
