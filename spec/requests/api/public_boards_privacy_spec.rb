require "rails_helper"

# The board catalogue is serialized for callers who may not be signed in, so a
# card must not carry communicator identity — names, usernames or avatars.
# `Board#public_card_view` documents the same rule for public pages; these
# specs pin it on this endpoint.
RSpec.describe "API public_boards communicator privacy", type: :request do
  # public_boards scopes to User::DEFAULT_ADMIN_ID, so the admin must own that id.
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  let!(:library_board) do
    create(:board, user: admin, name: "Core 60", predefined: true, published: true)
  end

  # A family using a catalogue board — the identity that must not appear.
  let!(:parent)       { create(:user) }
  let!(:communicator) { create(:child_account, user: parent, name: "Mason", username: "mason-r") }

  before do
    communicator.child_boards.create!(board: library_board, created_by_id: parent.id)
  end

  def card_for(board)
    JSON.parse(response.body)["public_boards"].find { |b| b["id"] == board.id }
  end

  it "names no communicator to an unauthenticated caller" do
    get "/api/public_boards"

    expect(response).to have_http_status(:ok)
    card = card_for(library_board)

    expect(card).to be_present
    expect(card["in_use_by"]).to be_nil
    expect(card["communicator_account_data"]).to eq([])
  end

  it "leaks no communicator name, username or avatar anywhere in the payload" do
    get "/api/public_boards"

    expect(response.body).not_to include("Mason")
    expect(response.body).not_to include("mason-r")
  end

  it "names no communicator to a signed-in stranger" do
    stranger = create(:user)
    get "/api/public_boards", headers: auth_headers(stranger)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Mason")
  end
end
