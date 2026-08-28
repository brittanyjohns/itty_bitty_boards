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

  it "reports can_edit false for another user" do
    other = create(:user)

    get "/api/boards/#{board.id}/predictive_image_board", headers: auth_headers(other)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be false
  end

  it "reports can_edit false for an anonymous viewer" do
    get "/api/boards/#{board.id}/predictive_image_board"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be false
  end

  it "agrees with boards#show for a plan-locked board" do
    free_user = create(:free_user)
    editable_board = create(:board, user: free_user, name: "Editable")
    locked_board = create(:board, user: free_user, name: "Locked")
    free_user.update!(editable_board_id: editable_board.id)

    get "/api/boards/#{locked_board.id}/predictive_image_board", headers: auth_headers(free_user)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be false

    get "/api/boards/#{editable_board.id}/predictive_image_board", headers: auth_headers(free_user)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["can_edit"]).to be true
  end
end
