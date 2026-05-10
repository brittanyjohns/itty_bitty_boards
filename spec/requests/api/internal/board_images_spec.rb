require "rails_helper"

RSpec.describe "API::Internal::BoardImages", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}", "Content-Type" => "application/json" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let!(:board) { create(:board, user: admin_user) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  describe "POST /api/internal/boards/:board_id/board_images" do
    it "returns 401 without a valid bearer token" do
      post "/api/internal/boards/#{board.id}/board_images", params: { label: "apple" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 when neither image_id nor label is given" do
      post "/api/internal/boards/#{board.id}/board_images",
           params: {}.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/image_id or label is required/)
    end

    it "adds a cell using an existing image_id and returns 201" do
      image = create(:image, label: "kiwi", user_id: admin_user.id)

      expect {
        post "/api/internal/boards/#{board.id}/board_images",
             params: { image_id: image.id }.to_json,
             headers: auth_headers
      }.to change { board.reload.board_images.count }.by(1)

      expect(response).to have_http_status(:created)
      bi = board.board_images.last
      expect(bi.image_id).to eq(image.id)
    end

    it "creates an Image when only label is given and adds the cell" do
      expect {
        post "/api/internal/boards/#{board.id}/board_images",
             params: { label: "mango" }.to_json,
             headers: auth_headers
      }.to change(Image, :count).by(1)
       .and change { board.reload.board_images.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(Image.last.label).to eq("mango")
    end

    it "honors an explicit position" do
      image = create(:image, label: "pear", user_id: admin_user.id)

      post "/api/internal/boards/#{board.id}/board_images",
           params: { image_id: image.id, position: 7 }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      expect(board.board_images.last.position).to eq(7)
    end

    it "honors an explicit display_label" do
      image = create(:image, label: "thank you", user_id: admin_user.id)

      post "/api/internal/boards/#{board.id}/board_images",
           params: { image_id: image.id, display_label: "🙏" }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      expect(board.board_images.last.display_label).to eq("🙏")
    end
  end
end
