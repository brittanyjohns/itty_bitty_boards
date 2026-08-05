require "rails_helper"

RSpec.describe "API::Internal::BoardImages", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}", "Content-Type" => "application/json" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let!(:board) { create(:board, user: admin_user) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
    allow(GenerateImagesJob).to receive(:perform_async)
  end

  def with_art(image, count: 1)
    count.times { create(:doc, documentable: image, user: admin_user) }
    image
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

      expect(response).to have_http_status(:unprocessable_content)
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

    context "folder tiles (predictive_board_id)" do
      let!(:target_board) { create(:board, user: admin_user, name: "Feelings") }

      it "links a tile to another board and reports it as dynamic" do
        image = create(:image, label: "feelings-folder", user_id: admin_user.id)

        post "/api/internal/boards/#{board.id}/board_images",
             params: { image_id: image.id, predictive_board_id: target_board.id }.to_json,
             headers: auth_headers

        expect(response).to have_http_status(:created)
        bi = board.board_images.last
        expect(bi.predictive_board_id).to eq(target_board.id)
        expect(bi.is_dynamic?).to eq(true)
        expect(JSON.parse(response.body)["dynamic"]).to eq(true)
      end

      it "degrades to a plain word tile when the target board does not exist" do
        image = create(:image, label: "dangling-folder", user_id: admin_user.id)

        post "/api/internal/boards/#{board.id}/board_images",
             params: { image_id: image.id, predictive_board_id: 0 }.to_json,
             headers: auth_headers

        # check_predictive_board nulls the id rather than raising, which is what
        # lets this attribute be permitted without extra validation.
        expect(response).to have_http_status(:created)
        bi = board.board_images.last
        expect(bi.predictive_board_id).to be_nil
        expect(bi.is_dynamic?).to eq(false)
      end

      it "does not treat a self-link as dynamic" do
        image = create(:image, label: "self-folder", user_id: admin_user.id)

        post "/api/internal/boards/#{board.id}/board_images",
             params: { image_id: image.id, predictive_board_id: board.id }.to_json,
             headers: auth_headers

        expect(response).to have_http_status(:created)
        expect(board.board_images.last.is_dynamic?).to eq(false)
      end
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

      expect(response).to have_http_status(:unprocessable_content)
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

    it "mixes linked folder tiles and plain word tiles in one request" do
      food = create(:board, user: admin_user, name: "Food")
      play = create(:board, user: admin_user, name: "Play")
      word = create(:image, label: "want-bulk", user_id: admin_user.id)
      food_tile = create(:image, label: "food-folder-bulk", user_id: admin_user.id)
      play_tile = create(:image, label: "play-folder-bulk", user_id: admin_user.id)

      post "/api/internal/boards/#{board.id}/board_images/bulk",
           params: {
             cells: [
               { image_id: word.id, position: 0 },
               { image_id: food_tile.id, position: 1, predictive_board_id: food.id },
               { image_id: play_tile.id, position: 2, predictive_board_id: play.id },
             ],
           }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      created = board.reload.board_images.order(:position).to_a
      expect(created.map(&:predictive_board_id)).to eq([nil, food.id, play.id])
      expect(JSON.parse(response.body).map { |c| c["dynamic"] }).to eq([false, true, true])
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

      expect(response).to have_http_status(:unprocessable_content)
      errors = JSON.parse(response.body)["errors"]
      expect(errors).to be_an(Array)
      expect(errors.first["index"]).to eq(1)
      expect(errors.first["error"]).to match(/image_id or label is required/)
    end
  end

  # Regression coverage for #572: label resolution used a naive `find_by`, which
  # returns arbitrary Postgres heap order and routinely attached a blank,
  # art-less duplicate instead of the illustrated library image.
  describe "label resolution" do
    def bulk_post(cells, extra = {})
      post "/api/internal/boards/#{board.id}/board_images/bulk",
           params: { cells: cells }.merge(extra).to_json,
           headers: auth_headers
    end

    it "attaches the art-bearing image, not a lower-id blank duplicate" do
      blank = create(:image, label: "run", user_id: admin_user.id)
      arted = with_art(create(:image, label: "run", user_id: admin_user.id))

      bulk_post([{ label: "run", position: 0 }])

      expect(response).to have_http_status(:created)
      expect(board.reload.board_images.last.image_id).to eq(arted.id)
      expect(board.board_images.last.image_id).not_to eq(blank.id)
    end

    it "prefers the image with the most artwork when several have art" do
      few  = with_art(create(:image, label: "ball", user_id: admin_user.id), count: 1)
      many = with_art(create(:image, label: "ball", user_id: admin_user.id), count: 3)

      bulk_post([{ label: "ball" }])

      expect(board.reload.board_images.last.image_id).to eq(many.id)
      expect(board.board_images.last.image_id).not_to eq(few.id)
    end

    it "matches the label case-insensitively instead of creating a duplicate" do
      arted = with_art(create(:image, label: "stop", user_id: admin_user.id))

      expect {
        bulk_post([{ label: "Stop" }])
      }.not_to change(Image, :count)

      expect(board.reload.board_images.last.image_id).to eq(arted.id)
    end

    it "keeps the caller's authored casing as the cell's display_label" do
      with_art(create(:image, label: "stop", user_id: admin_user.id))

      bulk_post([{ label: "Stop" }])

      expect(board.reload.board_images.last.display_label).to eq("Stop")
    end

    it "does not override an explicit display_label with the authored casing" do
      with_art(create(:image, label: "stop", user_id: admin_user.id))

      bulk_post([{ label: "Stop", display_label: "🛑" }])

      expect(board.reload.board_images.last.display_label).to eq("🛑")
    end

    it "still pins the exact record when image_id is given" do
      blank = create(:image, label: "run", user_id: admin_user.id)
      with_art(create(:image, label: "run", user_id: admin_user.id))

      bulk_post([{ image_id: blank.id }])

      expect(board.reload.board_images.last.image_id).to eq(blank.id)
    end

    it "creates the image with create! so validation failures surface" do
      expect {
        bulk_post([{ label: "zzz-brand-new-word" }])
      }.to change(Image, :count).by(1)

      expect(Image.last.label).to eq("zzz-brand-new-word")
    end
  end

  # #572, second bug: a tile created for a label with no library art used to
  # stay permanently blank — nothing in this flow enqueued generation.
  describe "AI art for labels with no library art" do
    def bulk_post(cells, extra = {})
      post "/api/internal/boards/#{board.id}/board_images/bulk",
           params: { cells: cells }.merge(extra).to_json,
           headers: auth_headers
    end

    it "enqueues generation for a label that resolved to an art-less image" do
      bulk_post([{ label: "zzz-no-art-anywhere" }])

      expect(response).to have_http_status(:created)
      image = Image.find_by(label: "zzz-no-art-anywhere")
      expect(GenerateImagesJob).to have_received(:perform_async).with([image.id], board.id)
    end

    it "enqueues for an existing blank image, not just a newly created one" do
      blank = create(:image, label: "zzz-existing-blank", user_id: admin_user.id)

      bulk_post([{ label: "zzz-existing-blank" }])

      expect(GenerateImagesJob).to have_received(:perform_async).with([blank.id], board.id)
    end

    it "does not enqueue when the label already has art" do
      with_art(create(:image, label: "apple-arted", user_id: admin_user.id))

      bulk_post([{ label: "apple-arted" }])

      expect(GenerateImagesJob).not_to have_received(:perform_async)
    end

    it "does not enqueue for the explicit image_id path" do
      blank = create(:image, label: "pinned-blank", user_id: admin_user.id)

      bulk_post([{ image_id: blank.id }])

      expect(GenerateImagesJob).not_to have_received(:perform_async)
    end

    it "does not enqueue when generate_missing is false" do
      bulk_post([{ label: "zzz-opted-out" }], generate_missing: false)

      expect(response).to have_http_status(:created)
      expect(GenerateImagesJob).not_to have_received(:perform_async)
    end

    it "batches in slices of three" do
      labels = (1..4).map { |i| { label: "zzz-batch-#{i}" } }

      bulk_post(labels)

      expect(GenerateImagesJob).to have_received(:perform_async).twice
    end

    it "enqueues nothing when the bulk request rolls back" do
      bulk_post([{ label: "zzz-rolled-back" }, { position: 1 }])

      expect(response).to have_http_status(:unprocessable_content)
      expect(GenerateImagesJob).not_to have_received(:perform_async)
    end

    it "enqueues for the single-cell endpoint too" do
      post "/api/internal/boards/#{board.id}/board_images",
           params: { label: "zzz-single-no-art" }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      image = Image.find_by(label: "zzz-single-no-art")
      expect(GenerateImagesJob).to have_received(:perform_async).with([image.id], board.id)
    end
  end
end
