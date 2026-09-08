require "rails_helper"

# GET /api/boards/list is the quick-add picker's source for a USER token.
#
# Assignment ATTACHES a board rather than copying it, so one board sits on N
# dashboards and a word added here reaches all of them. The picker had no way
# to say so. Nobody is blocked — these two fields drive a badge and a
# confirm-once-per-board dialog.
RSpec.describe "API::Boards list share flags", type: :request do
  let(:owner) { create(:user) }
  let(:communicator) { create(:child_account, user: owner, name: "Leo") }

  def board(name, user: owner)
    create(:board, user: user, name: name)
  end

  def list(params = {}, headers: auth_headers(owner))
    get "/api/boards/list", params: params, headers: headers
    JSON.parse(response.body)["boards"].index_by { |b| b["name"] }
  end

  it "reports an unattached board as not shared" do
    board("Alone")

    expect(list["Alone"]).to include("shared_with_communicators" => false)
  end

  it "reports a board on a communicator dashboard as shared" do
    root = board("Core 84")
    create(:child_board, board: root, child_account: communicator)

    expect(list["Core 84"]).to include(
      "shared_with_communicators" => true,
      # #877's field, answering the neighbouring question: WHICH of the
      # viewer's own communicators. Both ship; neither derives the other.
      "in_use_by" => "Leo",
    )
  end

  # The page carries no child_boards row of its own — it inherits from the root
  # that reaches it, because that is how the sibling actually opens it.
  it "reports a page of a shared set as shared" do
    root = board("Core 84")
    page = board("Food")
    create(:board_image, board: root, predictive_board_id: page.id)
    create(:child_board, board: root, child_account: communicator)

    expect(list["Food"]).to include("shared_with_communicators" => true)
  end

  it "excludes the named communicator so a board only they use reads unshared" do
    root = board("Core 84")
    create(:child_board, board: root, child_account: communicator)

    rows = list({ communicator_id: communicator.id })

    expect(rows["Core 84"]["shared_with_communicators"]).to be(false)
  end

  it "still reports sharing when a second communicator has it" do
    sibling = create(:child_account, user: owner, name: "Maya")
    root = board("Core 84")
    create(:child_board, board: root, child_account: communicator)
    create(:child_board, board: root, child_account: sibling)

    rows = list({ communicator_id: communicator.id })

    expect(rows["Core 84"]["shared_with_communicators"]).to be(true)
  end

  it "ignores a communicator_id belonging to somebody else" do
    stranger = create(:child_account, user: create(:user), name: "Wilhelmina")
    root = board("Core 84")
    create(:child_board, board: root, child_account: stranger)

    rows = list({ communicator_id: stranger.id })

    # Not silently honoured as a filter: the board is still shared.
    expect(rows["Core 84"]["shared_with_communicators"]).to be(true)
  end

  # A stranger who assigned a published board is real sharing, but naming a
  # number for communicators the user may not know about makes the badge noise.
  it "reports sharing without naming a communicator the user does not own" do
    stranger = create(:child_account, user: create(:user), name: "Wilhelmina")
    root = board("Core 84")
    create(:child_board, board: root, child_account: stranger)

    row = list["Core 84"]

    # The case that makes these two fields complementary rather than
    # duplicative: in_use_by names only communicators the viewer owns, so it is
    # nil, while the word added here really does reach another dashboard.
    expect(row["shared_with_communicators"]).to be(true)
    expect(row["in_use_by"]).to be_nil
    expect(response.body).not_to include("Wilhelmina")
  end

  # Board#recalculate_in_use! writes with update_column, so attaching a board
  # bumps no updated_at the old ETag tuple could see. Without the share
  # fingerprint this flag would sit frozen behind a 304 and read as a caching
  # bug for weeks.
  it "revalidates after a board is attached to a dashboard" do
    root = board("Core 84")

    get "/api/boards/list", headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    etag = response.headers["ETag"]
    expect(etag).to be_present

    get "/api/boards/list", headers: auth_headers(owner).merge("HTTP_IF_NONE_MATCH" => etag)
    expect(response).to have_http_status(:not_modified)

    create(:child_board, board: root, child_account: communicator)

    get "/api/boards/list", headers: auth_headers(owner).merge("HTTP_IF_NONE_MATCH" => etag)
    expect(response).to have_http_status(:ok)

    rows = JSON.parse(response.body)["boards"].index_by { |b| b["name"] }
    expect(rows["Core 84"]["shared_with_communicators"]).to be(true)
  end

  # #877's ETag terms are keyed on the CALLER's own communicators, so a
  # stranger attaching one of this user's boards is invisible to them. Only the
  # boards-keyed share fingerprint catches it — which is why both sets of terms
  # are in the tuple rather than one standing in for the other.
  it "revalidates when somebody else's communicator attaches one of these boards" do
    root = board("Core 84")

    get "/api/boards/list", headers: auth_headers(owner)
    etag = response.headers["ETag"]

    get "/api/boards/list", headers: auth_headers(owner).merge("HTTP_IF_NONE_MATCH" => etag)
    expect(response).to have_http_status(:not_modified)

    stranger = create(:child_account, user: create(:user), name: "Wilhelmina")
    create(:child_board, board: root, child_account: stranger)

    get "/api/boards/list", headers: auth_headers(owner).merge("HTTP_IF_NONE_MATCH" => etag)
    expect(response).to have_http_status(:ok)

    rows = JSON.parse(response.body)["boards"].index_by { |b| b["name"] }
    expect(rows["Core 84"]["shared_with_communicators"]).to be(true)
  end

  it "leaves the existing payload keys alone" do
    board("Alone")

    row = list["Alone"]

    expect(row.keys).to include(
      "id", "board_id", "name", "slug", "can_edit", "locked", "user_id",
      "images_ready", "tiles_awaiting_art", "display_image_url",
      "in_use", "in_use_by",
    )
  end
end
