require "rails_helper"

# Speak mode loads GET /api/boards/:id/predictive_image_board and gates its
# "Edit this board" menu row on can_edit, so this payload has to answer the
# same question boards#show does — see issue #793.
RSpec.describe "GET /api/boards/:id/predictive_image_board", type: :request do
  let(:owner) { create(:user) }
  let!(:board) { create(:board, user: owner, name: "Speak me") }

  it "reports can_edit true for the board's owner" do
    get "/api/boards/#{board.id}/predictive_image_board", headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be true
  end

  # Same reason as the anonymous case: a non-owner can only reach a board they
  # are allowed to see, so can_edit is asked on a published one.
  it "reports can_edit false for another user" do
    other = create(:user)
    published = create(:board, user: owner, name: "Speak me publicly", published: true)

    get "/api/boards/#{published.id}/predictive_image_board", headers: auth_headers(other)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be false
  end

  # A private board 404s an anonymous caller (see the authorization block
  # below), so the can_edit question is only askable on a published one.
  it "reports can_edit false for an anonymous viewer" do
    published = create(:board, user: owner, name: "Speak me publicly", published: true)

    get "/api/boards/#{published.id}/predictive_image_board"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be false
  end

  it "agrees with boards#show for a plan-locked board" do
    free_user = create(:free_user)
    editable_board = create(:board, user: free_user, name: "Editable")
    # Past EDITABLE_BOARD_FLOOR, or nothing is locked to compare against: the
    # editable subset is max(board_limit, floor), not board_limit.
    Array.new(User::EDITABLE_BOARD_FLOOR) { create(:board, user: free_user) }
    locked_board = create(:board, user: free_user, name: "Locked")
    locked_board.update_column(:updated_at, 30.days.ago)
    free_user.update!(editable_board_id: editable_board.id)

    get "/api/boards/#{locked_board.id}/predictive_image_board", headers: auth_headers(free_user)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be false

    get "/api/boards/#{editable_board.id}/predictive_image_board", headers: auth_headers(free_user)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be true
  end
end

# `predictive_image_board` is on the controller's
# `skip_before_action :authenticate_token!` list and resolves its board through
# `find_board_for_predictive_page`, which scopes by nothing — so the action's own
# `viewable_by?` guard is all that stands between an incrementing integer and
# every private board's full tile payload (labels, symbols, and a board name that
# routinely carries a child's first name). Same generic 404 `show` and `pdf`
# return, so we never confirm the board exists. See issue #852.
RSpec.describe "GET /api/boards/:id/predictive_image_board authorization", type: :request do
  let!(:owner) { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:private_board) { create(:board, user: owner, name: "Private Speak Board") }
  let!(:public_board) { create(:board, user: owner, name: "Public Speak Board", published: true) }

  it "lets an anonymous caller open a published board" do
    get "/api/boards/#{public_board.id}/predictive_image_board"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["id"]).to eq(public_board.id)
  end

  it "404s an anonymous caller asking for a private board" do
    get "/api/boards/#{private_board.id}/predictive_image_board"

    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to eq("Board not found")
  end

  it "lets the owner open their own private board" do
    get "/api/boards/#{private_board.id}/predictive_image_board", headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["id"]).to eq(private_board.id)
  end

  it "404s a signed-in non-owner asking for a private board" do
    get "/api/boards/#{private_board.id}/predictive_image_board", headers: auth_headers(other_user)

    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to eq("Board not found")
  end

  it "lets a communicator open a private board belonging to their own account" do
    communicator = create(:child_account, user: owner)

    get "/api/boards/#{private_board.id}/predictive_image_board", headers: auth_headers(communicator)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["id"]).to eq(private_board.id)
  end

  it "404s a communicator asking for a private board on someone else's account" do
    communicator = create(:child_account, user: other_user)

    get "/api/boards/#{private_board.id}/predictive_image_board", headers: auth_headers(communicator)

    expect(response).to have_http_status(:not_found)
  end

  # The ambiguous half of #852, pinned deliberately: `find_board_for_predictive_page`
  # falls back to `Board.predictive_default` when the id/slug matches nothing, and
  # that fallback is preserved — but the guard runs on whatever it RESOLVES, so a
  # refusal is never quietly answered with a different board's payload.
  it "still serves the predictive default when the id matches no board" do
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID) ||
            create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    default_board = create(:board, user: admin, name: "Predictive Default",
                                   parent_type: "PredefinedResource", published: true)

    get "/api/boards/999999999/predictive_image_board"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["id"]).to eq(default_board.id)
  end

  it "404s rather than falling back when the named board exists but is not viewable" do
    get "/api/boards/#{private_board.id}/predictive_image_board", headers: auth_headers(other_user)

    expect(response).to have_http_status(:not_found)
  end
end
