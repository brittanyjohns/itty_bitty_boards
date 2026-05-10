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

    it "persists per-cell style overrides (hidden/font/border/colors)" do
      image = create(:image, label: "kiwi-style", user_id: admin_user.id)

      post "/api/internal/boards/#{board.id}/board_images",
           params: {
             image_id: image.id,
             hidden: true,
             font_size: 28,
             border_width: 4,
             border_radius: 12,
             bg_color: "yellow",
             text_color: "#000000",
             border_color: "rgb(255, 0, 0)",
           }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      bi = board.board_images.last
      expect(bi.hidden).to eq(true)
      expect(bi.font_size).to eq(28)
      expect(bi.border_width).to eq(4)
      expect(bi.border_radius).to eq(12)
      expect(bi.bg_color).to eq("#FFEA75")           # word -> hex via ColorHelper
      expect(bi.text_color).to eq("#000000")
      expect(bi.border_color).to eq("#FF0000")       # rgb() -> hex via ColorHelper
    end

    it "merges hide_label into the data jsonb without clobbering existing keys" do
      image = create(:image, label: "kiwi-data", user_id: admin_user.id)

      post "/api/internal/boards/#{board.id}/board_images",
           params: { image_id: image.id, hide_label: true }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      bi = board.board_images.last
      expect(bi.data).to include("hide_label" => true)
    end
  end

  describe "POST /api/internal/boards/:board_id/board_images/bulk" do
    it "returns 401 without a valid bearer token" do
      post "/api/internal/boards/#{board.id}/board_images/bulk",
           params: { cells: [{ label: "apple" }] }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 when cells is missing or empty" do
      post "/api/internal/boards/#{board.id}/board_images/bulk",
           params: { cells: [] }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/cells must be a non-empty array/)
    end

    it "creates N cells in one request and returns them in input order" do
      img_a = create(:image, label: "apple-bulk", user_id: admin_user.id)
      img_b = create(:image, label: "banana-bulk", user_id: admin_user.id)
      img_c = create(:image, label: "cherry-bulk", user_id: admin_user.id)

      expect {
        post "/api/internal/boards/#{board.id}/board_images/bulk",
             params: {
               cells: [
                 { image_id: img_a.id, position: 0, bg_color: "yellow", hide_label: true },
                 { image_id: img_b.id, position: 1, border_width: 6 },
                 { image_id: img_c.id, position: 2 },
               ],
             }.to_json,
             headers: auth_headers
      }.to change { board.reload.board_images.count }.by(3)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.size).to eq(3)
      expect(body.map { |c| c["image_id"] }).to eq([img_a.id, img_b.id, img_c.id])

      created = board.board_images.order(:position).to_a
      expect(created[0].bg_color).to eq("#FFEA75")
      expect(created[0].data).to include("hide_label" => true)
      expect(created[1].border_width).to eq(6)
    end

    it "rolls back atomically when any entry is invalid" do
      img_a = create(:image, label: "apple-rb", user_id: admin_user.id)

      expect {
        post "/api/internal/boards/#{board.id}/board_images/bulk",
             params: {
               cells: [
                 { image_id: img_a.id, position: 0 },
                 { position: 1 }, # missing image_id and label — should fail
               ],
             }.to_json,
             headers: auth_headers
      }.not_to change { board.reload.board_images.count }

      expect(response).to have_http_status(:unprocessable_entity)
      errors = JSON.parse(response.body)["errors"]
      expect(errors).to be_an(Array)
      expect(errors.first["index"]).to eq(1)
      expect(errors.first["error"]).to match(/image_id or label is required/)
    end
  end
end
