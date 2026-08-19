require "rails_helper"

# The boards page defaults to the "Main Boards" filter. An imported .obz set has
# to read there like any other board: one entry, its root — not thirty pages,
# and not nothing at all (which is what the blanket `where(obf_id: nil)` on the
# discovery scopes used to produce).
RSpec.describe "API::Boards imported set listing", type: :request do
  let(:user) { create(:user) }

  def board_names(response)
    JSON.parse(response.body).fetch("boards").map { |b| b["name"] }
  end

  let!(:root) do
    create(:board, user: user, name: "Imported Core Set", obf_id: "core", board_type: "dynamic")
  end
  let!(:page_board) do
    create(:board, user: user, name: "Imported Food Page", obf_id: "food", board_type: "category")
  end

  before do
    create(:board_image, board: root, predictive_board_id: page_board.id)
    # Every page of a real set carries a way home; without the back-tile flag
    # this link is what would demote the root on its next save.
    create(:board_image, board: page_board, predictive_board_id: root.id, data: { "back_tile" => true })
    Boards::ImportedSetClassifier.new(root).call
  end

  it "shows the set's root under the Main Boards filter and hides its pages" do
    get "/api/boards", params: { filter: "main_boards", per_page: 50 }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(board_names(response)).to include("Imported Core Set")
    expect(board_names(response)).not_to include("Imported Food Page")
  end

  it "finds the set's root by name in search" do
    get "/api/boards", params: { query: "Imported Core", per_page: 50 }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(board_names(response)).to include("Imported Core Set")
  end

  it "still lists every page under the All filter, so board_count matches" do
    get "/api/boards", params: { filter: "all", per_page: 50 }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(board_names(response)).to include("Imported Core Set", "Imported Food Page")
  end
end
