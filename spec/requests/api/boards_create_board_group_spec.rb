require "rails_helper"

RSpec.describe "API::Boards#create_board_group", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  def add_tile(board, label:, links_to: nil)
    image = FactoryBot.create(:image, label: label)
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: links_to&.id)
  end

  let!(:home) { create(:board, user: user, name: "Home") }
  let!(:food) { create(:board, user: user, name: "Food") }

  before { add_tile(home, label: "Food", links_to: food) }

  it "creates a group for the board and returns it" do
    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["root_board_id"]).to eq(home.id)
    board_ids = body["boards"].map { |b| b["board_id"] }
    expect(board_ids).to contain_exactly(home.id, food.id)
  end

  it "returns the existing group (200) instead of duplicating it" do
    existing = home.board_groups.create!(user: user, name: "Existing", builder: true)
    existing.add_board(home)

    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["id"]).to eq(existing.id)
  end

  it "returns 401 for a non-owner, non-admin user" do
    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(other_user)

    expect(response).to have_http_status(:unauthorized)
    expect(BoardGroup.where(root_board_id: home.id)).to be_empty
  end

  it "returns the standard board-set-limit 422 shape when the user is at their limit" do
    user.update!(settings: (user.settings || {}).merge("board_group_limit" => 0))

    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(user)

    expect(response).to have_http_status(:unprocessable_content)
    body = JSON.parse(response.body)
    expect(body["error"]).to be_present
    expect(body).to have_key("limit")
    expect(body).to have_key("count")
  end
end
