# frozen_string_literal: true

require "rails_helper"

# The read-only board lock is the BOARD OWNER's plan, not the caller's.
#
# `User#board_editable?` opens with `return true if board.user_id != id`, so
# `check_board_editable!` — which used to ask the CALLER — answered "not
# locked" for every board the caller did not own. The one path that reaches it
# as a non-owner today is quick add: a communicator adding a word to a board
# somebody else shared onto their dashboard through a team. So a locked board
# was writable through any communicator whose own adult's plan was fine.
#
# Also pinned here: a non-owner's refusal must not carry `board_limit` or
# `editable_board_id`. Those are the owner's plan tier and the id of another of
# their boards — private data, and useless to a caller who cannot act on them.
RSpec.describe "Board lock follows the owner's plan", type: :request do
  # An SLP on Free, one board past the editable-slot floor, so exactly one of
  # her boards is read-only. Ordered oldest-first so recency drops `boards.first`.
  let(:slp) { create(:free_user) }
  let!(:slp_boards) do
    Array.new(User::EDITABLE_BOARD_FLOOR + 1) { create(:board, user: slp, name: "SLP board") }
      .each_with_index { |b, i| b.update_column(:updated_at, (20 - i).days.ago) }
  end
  let(:locked_board) { slp_boards.first }

  # A family on Pro, with a communicator, on a team the SLP shared into.
  let(:parent) { create(:user, plan_type: "pro") }
  let(:communicator) { create(:child_account, user: parent, owner: parent) }
  let!(:team) do
    t = communicator.ensure_team!(creator: parent)
    t.upsert_member!(slp, "supervisor")
    t.add_board!(locked_board, slp.id)
    t
  end

  before { create(:child_board, board: locked_board, child_account: communicator) }

  it "refuses a communicator quick-adding to a board whose owner is locked" do
    expect {
      post "/api/boards/#{locked_board.id}/add_image",
           params: { image: { label: "carpet time" } },
           headers: auth_headers(communicator)
    }.not_to change(Image, :count)

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("board_locked_owner_plan")
  end

  it "does not leak the owner's plan limit or their other board's id" do
    post "/api/boards/#{locked_board.id}/add_image",
         params: { image: { label: "carpet time" } },
         headers: auth_headers(communicator)

    body = JSON.parse(response.body)
    expect(body).not_to have_key("board_limit")
    expect(body).not_to have_key("editable_board_id")
  end

  it "still allows quick add when the owner's plan is not locking that board" do
    editable = slp_boards.last
    team.add_board!(editable, slp.id)
    create(:child_board, board: editable, child_account: communicator)

    expect {
      post "/api/boards/#{editable.id}/add_image",
           params: { image: { label: "book bin" } },
           headers: auth_headers(communicator)
    }.to change(Image, :count).by(1)

    expect(response).to have_http_status(:ok)
  end

  describe "the owner themselves" do
    it "still gets board_locked with the upgrade path" do
      patch "/api/boards/#{locked_board.id}",
            params: { board: { name: "Nope" } },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("board_locked")
      expect(body).to have_key("board_limit")
      expect(body).to have_key("editable_board_id")
    end
  end

  # `check_board_image_editable!` had the same bug one controller over, plus a
  # nil-user path that read `current_user.board_limit` after a `current_user&.`
  # guard had already admitted nil.
  describe "API::BoardImages" do
    let!(:tile) { create(:board_image, board: locked_board) }

    # Adding a tile touches the board, which would make it the owner's
    # most-recently-updated board and so one of the ones recency keeps
    # editable. Re-age it so it is still the board the lock drops.
    before { locked_board.update_column(:updated_at, 30.days.ago) }

    it "refuses the owner's own tile edit on a locked board, with the upgrade path" do
      patch "/api/board_images/#{tile.id}",
            params: { board_image: { label: "renamed" } },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("board_locked")
      expect(body).to have_key("board_limit")
    end

    # A non-owner does not reach the plan gate here at all: this controller's
    # `set_owned_board_image` scopes the lookup to boards the caller owns, so a
    # stranger 404s first. Pinned so the ordering is deliberate rather than
    # accidental — per-board edit grants will change who gets past it, and the
    # plan gate has to still be the thing that answers next.
    it "404s a non-owner before the plan gate is consulted" do
      patch "/api/board_images/#{tile.id}",
            params: { board_image: { label: "renamed" } },
            headers: auth_headers(parent)

      expect(response).to have_http_status(:not_found)
    end

    it "lets the owner edit a tile on a board still in their editable slots" do
      unlocked_tile = create(:board_image, board: slp_boards.last)

      patch "/api/board_images/#{unlocked_tile.id}",
            params: { board_image: { label: "renamed" } },
            headers: auth_headers(slp)

      expect(response).to have_http_status(:success)
    end
  end
end
