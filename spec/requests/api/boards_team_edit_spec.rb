# frozen_string_literal: true

require "rails_helper"

# A per-board edit grant lets an SLP add "book bin" and "Miss Reyes" to the
# family's actual board, instead of forking it into a divergent school copy.
#
# It is narrow on purpose. Deletion, AI spend, whole-board sweeps and the board
# cover stay with the owner, on a separate `before_action` list — and the last
# example in this file asserts that split arithmetically, so the two lists
# cannot drift apart or leave an action ungated.
RSpec.describe "API::Boards per-board team edit grants", type: :request do
  let(:parent) { create(:user, plan_type: "pro") }
  let(:board) { create(:board, user: parent, name: "Eli's Core Words") }
  let!(:tile) { create(:board_image, board: board) }

  let(:communicator) { create(:child_account, user: parent, owner: parent) }
  let!(:team) { communicator.ensure_team!(creator: parent) }

  let(:slp) { create(:user, plan_type: "pro") }

  def join!(user, role)
    team.upsert_member!(user, role)
  end

  def grant!
    team.add_board!(board, parent.id)
    TeamBoard.find_by(board_id: board.id, team_id: team.id).update!(allow_edit: true)
  end

  describe "a granted supervisor" do
    before do
      join!(slp, "supervisor")
      grant!
    end

    it "can add a word to the board" do
      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "book bin" } },
             headers: auth_headers(slp)
      }.to change(Image, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    # The only trace the owner gets that a tile came from someone else.
    it "stamps who added the tile" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "miss reyes" } },
           headers: auth_headers(slp)

      added = board.reload.board_images.find_by(label: "miss reyes")
      expect(added.data["added_by_id"]).to eq(slp.id)
      expect(added.data["added_by_at"]).to be_present
    end

    it "does not stamp attribution when the OWNER adds a tile" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "snack" } },
           headers: auth_headers(parent)

      added = board.reload.board_images.find_by(label: "snack")
      expect(added.data["added_by_id"]).to be_nil
    end

    it "can save the layout" do
      post "/api/boards/#{board.id}/save_layout",
           params: {
             layout: [{ i: tile.id.to_s, x: 1, y: 0, w: 1, h: 1 }],
             screen_size: "lg",
           },
           headers: auth_headers(slp)

      expect(response).to have_http_status(:success)
    end

    it "can rename a tile" do
      patch "/api/board_images/#{tile.id}",
            params: { board_image: { label: "renamed" } },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:success)
    end

    it "can change board content through #update" do
      patch "/api/boards/#{board.id}",
            params: { board: { bg_color: "#ff0000", description: "school words" } },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      expect(board.reload.description).to eq("school words")
    end

    describe "what the grant does NOT allow" do
      it "cannot delete the board" do
        expect {
          delete "/api/boards/#{board.id}", headers: auth_headers(slp)
        }.not_to change(Board, :count)

        expect(response).to have_http_status(:forbidden)
      end

      it "cannot publish or rename it through #update" do
        patch "/api/boards/#{board.id}",
              params: { board: { published: true, name: "Renamed" } },
              headers: auth_headers(slp)

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("board_owner_only_change")
        expect(board.reload).to have_attributes(published: false, name: "Eli's Core Words")
      end

      it "cannot spend credits repainting the board's art" do
        expect(Sidekiq::Testing).to be_truthy # jobs are inlined/faked by the suite

        expect {
          post "/api/boards/#{board.id}/regenerate_images",
               params: { board_image_ids: [tile.id] },
               headers: auth_headers(slp)
        }.not_to change { CreditTransaction.count }

        expect(response).to have_http_status(:forbidden)
      end

      it "cannot run a whole-board sweep" do
        put "/api/boards/#{board.id}/set_colors",
            params: { bg_color: "#00ff00" },
            headers: auth_headers(slp)

        expect(response).to have_http_status(:forbidden)
      end

      it "cannot change the board's cover" do
        put "/api/boards/#{board.id}/set_display_image",
            params: { display_image_url: "https://example.com/x.png" },
            headers: auth_headers(slp)

        expect(response).to have_http_status(:forbidden)
      end

      # A vendor SLP editing a parent's board must not re-brand it.
      it "does not stamp its own vendor_id on the owner's board" do
        vendor_slp = create(:user, plan_type: "pro", vendor: create(:vendor, category: Vendor::CATEGORIES.first))
        join!(vendor_slp, "supervisor")

        patch "/api/boards/#{board.id}",
              params: { board: { bg_color: "#123456" } },
              headers: auth_headers(vendor_slp)

        expect(board.reload.vendor_id).to be_nil
      end
    end
  end

  # Sharing a board with a team is what makes it VISIBLE to that team
  # (`Board#viewable_by?`). A board that was never shared is refused with the
  # 404 shape; one shared WITHOUT `allow_edit` is visible but not writable, so
  # it gets the 403. The distinction is a question about visibility, not about
  # the write.
  describe "a supervisor with no grant" do
    before { join!(slp, "supervisor") }

    it "gets 404 on a board that was never shared with the team" do
      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "nope" } },
             headers: auth_headers(slp)
      }.not_to change(Image, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "gets 403 on a board shared with the team but not granted" do
      team.add_board!(board, parent.id)

      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "nope" } },
             headers: auth_headers(slp)
      }.not_to change(Image, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "is refused a tile rename" do
      patch "/api/board_images/#{tile.id}",
            params: { board_image: { label: "nope" } },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a granted Support member" do
    before do
      join!(slp, "member")
      grant!
    end

    it "is still refused — the grant does not reach that role" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "nope" } },
           headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "a stranger" do
    it "gets 404, not 403 — a private board must not be enumerable" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "nope" } },
           headers: auth_headers(create(:user))

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("Board not found")
    end
  end

  # The comment on the before_action lists claims their union is
  # check_board_editable!'s list plus #add_image, with no overlap. Assert it,
  # rather than trusting a comment: an action on NEITHER list is an ungated
  # action, and one on BOTH would answer the owner-only refusal first and make
  # every grant useless.
  describe "the before_action split" do
    def actions_for(callback_name)
      API::BoardsController._process_action_callbacks
                           .select { |cb| cb.filter == callback_name }
                           .flat_map { |cb| Array(cb.instance_variable_get(:@if)) }
                           .flat_map { |c| Array(c.instance_variable_get(:@actions)).to_a }
                           .map(&:to_sym).to_set
    end

    it "puts every gated action on exactly one list" do
      owner_only = actions_for(:check_board_view_edit_permissions)
      team_write = actions_for(:check_board_team_write_permissions)

      expect(owner_only).not_to be_empty
      expect(team_write).not_to be_empty
      # An action on BOTH would answer the owner-only refusal first, making
      # every grant useless on it.
      expect(owner_only & team_write).to be_empty,
        "on both lists: #{(owner_only & team_write).to_a}"
    end

    it "leaves no plan-gated action without a permission gate" do
      permission_gated = actions_for(:check_board_view_edit_permissions) |
                         actions_for(:check_board_team_write_permissions)
      plan_gated = actions_for(:check_board_editable!)

      # add_image is the one deliberate exclusion: check_communicator_board_access!
      # gates it and delegates to check_board_team_write_permissions for a user
      # token, because on a communicator token there is no current_user to check.
      # Anything else missing here is an UNGATED write.
      expect(plan_gated - permission_gated).to eq(Set[:add_image])
    end

    it "gates deletion by permission even though it is not plan-gated" do
      # A read-only board can still be deleted — the lock is about editing —
      # so #destroy is on the owner list and off the plan list. Pinned so the
      # asymmetry reads as deliberate.
      permission_gated = actions_for(:check_board_view_edit_permissions) |
                         actions_for(:check_board_team_write_permissions)

      expect(permission_gated - actions_for(:check_board_editable!)).to eq(Set[:destroy])
      expect(actions_for(:check_board_view_edit_permissions)).to include(:destroy)
    end
  end
end
