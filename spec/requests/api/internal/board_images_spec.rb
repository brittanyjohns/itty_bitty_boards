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

  # #574: bulk intermittently 500'd AFTER the cells had been written, so the
  # obvious client behaviour — retry on 5xx — silently duplicated every tile.
  describe "retry safety" do
    def bulk_post(cells, extra = {})
      post "/api/internal/boards/#{board.id}/board_images/bulk",
           params: { cells: cells }.merge(extra).to_json,
           headers: auth_headers
    end

    let!(:img_a) { create(:image, label: "retry-a", user_id: admin_user.id) }
    let!(:img_b) { create(:image, label: "retry-b", user_id: admin_user.id) }

    it "replays the original cells instead of duplicating them when the key repeats" do
      cells = [{ image_id: img_a.id, position: 0 }, { image_id: img_b.id, position: 1 }]

      bulk_post(cells, idempotency_key: "build-42")
      expect(response).to have_http_status(:created)
      first_ids = JSON.parse(response.body).map { |c| c["id"] }

      expect { bulk_post(cells, idempotency_key: "build-42") }
        .not_to change { board.reload.board_images.count }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Idempotent-Replay"]).to eq("true")
      expect(JSON.parse(response.body).map { |c| c["id"] }).to eq(first_ids)
    end

    it "still creates cells for a different key on the same board" do
      bulk_post([{ image_id: img_a.id }], idempotency_key: "build-1")

      expect { bulk_post([{ image_id: img_b.id }], idempotency_key: "build-2") }
        .to change { board.reload.board_images.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "duplicates as before when no key is supplied (behaviour is opt-in)" do
      bulk_post([{ image_id: img_a.id }])

      expect { bulk_post([{ image_id: img_a.id }]) }
        .to change { board.reload.board_images.count }.by(1)
    end

    it "does not remember a key for a request that rolled back" do
      bulk_post([{ image_id: img_a.id }, { position: 1 }], idempotency_key: "rolled-back")
      expect(response).to have_http_status(:unprocessable_content)
      expect(board.reload.settings.dig("internal_bulk_keys", "rolled-back")).to be_nil

      expect { bulk_post([{ image_id: img_a.id }], idempotency_key: "rolled-back") }
        .to change { board.reload.board_images.count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "replaces existing tiles when replace is true" do
      bulk_post([{ image_id: img_a.id }, { image_id: img_b.id }])
      expect(board.reload.board_images.count).to eq(2)

      bulk_post([{ image_id: img_a.id }], replace: true)

      expect(response).to have_http_status(:created)
      expect(board.reload.board_images.count).to eq(1)
      expect(board.board_images.first.image_id).to eq(img_a.id)
      # The board-level layout no longer references the replaced tiles.
      expect(board.reload.layout.values.flat_map(&:keys).uniq).to eq([board.board_images.first.id.to_s])
    end

    it "keeps other settings keys intact when remembering a key" do
      board.update!(settings: { "video_seeder" => true })

      bulk_post([{ image_id: img_a.id }], idempotency_key: "keep-settings")

      expect(board.reload.settings["video_seeder"]).to eq(true)
      expect(board.settings["internal_bulk_keys"]).to have_key("keep-settings")
    end
  end

  # #574, the other half: `api_view` costs several queries PER TILE, all run
  # after the transaction commits.
  describe "bulk response payload" do
    def bulk_post(cells, extra = {})
      post "/api/internal/boards/#{board.id}/board_images/bulk",
           params: { cells: cells }.merge(extra).to_json,
           headers: auth_headers
    end

    it "returns a compact cell payload by default" do
      image = create(:image, label: "compact", user_id: admin_user.id)

      bulk_post([{ image_id: image.id, bg_color: "yellow" }])

      cell = JSON.parse(response.body).first
      expect(cell).to include("id", "board_id", "image_id", "label", "display_label",
                              "position", "layout", "bg_color", "src", "dynamic", "data")
      expect(cell).not_to have_key("docs")
      expect(cell).not_to have_key("audio_files")
      expect(cell).not_to have_key("voice_list")
      expect(cell["bg_color"]).to eq("#FFEA75")
    end

    it "returns the full api_view when view=full is requested" do
      image = create(:image, label: "full-view", user_id: admin_user.id)

      bulk_post([{ image_id: image.id }], view: "full")

      cell = JSON.parse(response.body).first
      expect(cell).to include("docs", "audio_files", "voice_list", "board_name")
    end

    it "issues fewer queries than the full api_view for the same cells" do
      images = 6.times.map { |i| create(:image, label: "flat-#{i}", user_id: admin_user.id) }

      count_queries = lambda do |cells, extra|
        queries = 0
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:sql].to_s.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

          queries += 1
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          post "/api/internal/boards/#{board.id}/board_images/bulk",
               params: { cells: cells }.merge(extra).to_json, headers: auth_headers
        end
        queries
      end

      # Warm up first. The FIRST request in a process pays one-time costs the
      # comparison isn't about — Devise/JWT setup, association and schema caches
      # — and they all land on whichever side is measured first. That made the
      # result depend on what else had already run in the same process, so the
      # example passed or failed on shard composition rather than on the code.
      warmup = create(:image, label: "flat-warmup", user_id: admin_user.id)
      count_queries.call([{ image_id: warmup.id }], {})

      lean = count_queries.call(images.first(3).map { |i| { image_id: i.id } }, {})
      full = count_queries.call(images.last(3).map { |i| { image_id: i.id } }, { view: "full" })

      # The per-tile docs / audio / voice-list lookups in api_view are what a
      # 48-cell request was paying for AFTER the transaction committed.
      expect(lean).to be < full
    end
  end

  # #584: the internal API could create a tile but never correct one.
  describe "PATCH /api/internal/boards/:board_id/board_images/:id" do
    let!(:original) { with_art(create(:image, label: "more-unsafe", user_id: admin_user.id)) }
    let!(:replacement) { with_art(create(:image, label: "more", user_id: admin_user.id)) }
    let!(:cell) { board.add_image(original.id) }

    it "returns 401 without a valid bearer token" do
      patch "/api/internal/boards/#{board.id}/board_images/#{cell.id}", params: { bg_color: "red" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "swaps the image while preserving the BoardImage id and layout" do
      layout_before = cell.reload.layout
      board_layout_before = board.reload.layout

      patch "/api/internal/boards/#{board.id}/board_images/#{cell.id}",
            params: { image_id: replacement.id }.to_json,
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(cell.id)
      expect(cell.reload.image_id).to eq(replacement.id)
      expect(cell.layout).to eq(layout_before)
      expect(board.reload.layout).to eq(board_layout_before)
    end

    it "updates style attributes the same way bulk does at create time" do
      patch "/api/internal/boards/#{board.id}/board_images/#{cell.id}",
            params: { bg_color: "yellow", display_label: "MORE", hidden: true, hide_label: true }.to_json,
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      cell.reload
      expect(cell.bg_color).to eq("#FFEA75")
      expect(cell.display_label).to eq("MORE")
      expect(cell.hidden).to eq(true)
      expect(cell.data).to include("hide_label" => true)
    end

    it "does not rename the tile when only the image is swapped" do
      cell.update!(display_label: "more")

      patch "/api/internal/boards/#{board.id}/board_images/#{cell.id}",
            params: { image_id: replacement.id }.to_json,
            headers: auth_headers

      expect(cell.reload.display_label).to eq("more")
    end

    it "404s for a board_image belonging to another board, without writing" do
      other_board = create(:board, user: admin_user)
      other_cell = other_board.add_image(original.id)

      patch "/api/internal/boards/#{board.id}/board_images/#{other_cell.id}",
            params: { image_id: replacement.id }.to_json,
            headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(other_cell.reload.image_id).to eq(original.id)
    end

    it "422s for an image_id that does not exist" do
      patch "/api/internal/boards/#{board.id}/board_images/#{cell.id}",
            params: { image_id: 0 }.to_json,
            headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(cell.reload.image_id).to eq(original.id)
    end
  end

  describe "PATCH /api/internal/boards/:board_id/board_images/bulk_update" do
    let!(:image) { create(:image, label: "bulk-edit", user_id: admin_user.id) }
    let!(:cell_a) { board.add_image(image.id) }
    let!(:cell_b) { board.add_image(image.id) }

    it "updates several cells atomically" do
      patch "/api/internal/boards/#{board.id}/board_images/bulk_update",
            params: { cells: [{ id: cell_a.id, bg_color: "yellow" }, { id: cell_b.id, voice: "alloy" }] }.to_json,
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(cell_a.reload.bg_color).to eq("#FFEA75")
      expect(cell_b.reload.voice).to be_present
    end

    it "rolls back every cell when one is not on this board" do
      other_board = create(:board, user: admin_user)
      foreign = other_board.add_image(image.id)

      patch "/api/internal/boards/#{board.id}/board_images/bulk_update",
            params: { cells: [{ id: cell_a.id, bg_color: "yellow" }, { id: foreign.id, bg_color: "red" }] }.to_json,
            headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["errors"].first["index"]).to eq(1)
      expect(cell_a.reload.bg_color).not_to eq("#FFEA75")
    end

    it "422s when cells is empty" do
      patch "/api/internal/boards/#{board.id}/board_images/bulk_update",
            params: { cells: [] }.to_json,
            headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/internal/boards/:board_id/board_images/:id" do
    let!(:image) { create(:image, label: "deletable", user_id: admin_user.id) }
    let!(:cell_a) { board.add_image(image.id) }
    let!(:cell_b) { board.add_image(image.id) }

    it "removes the cell and drops it from the board's layout" do
      expect {
        delete "/api/internal/boards/#{board.id}/board_images/#{cell_a.id}", headers: auth_headers
      }.to change { board.reload.board_images.count }.by(-1)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("deleted" => true, "id" => cell_a.id)
      expect(board.reload.layout.values.flat_map(&:keys)).not_to include(cell_a.id.to_s)
      expect(BoardImage.find_by(id: cell_a.id)).to be_nil
    end

    it "keeps the surviving cells" do
      delete "/api/internal/boards/#{board.id}/board_images/#{cell_a.id}", headers: auth_headers

      expect(board.reload.board_images.pluck(:id)).to eq([cell_b.id])
    end

    it "404s for a board_image belonging to another board" do
      other_board = create(:board, user: admin_user)
      foreign = other_board.add_image(image.id)

      delete "/api/internal/boards/#{board.id}/board_images/#{foreign.id}", headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(BoardImage.find_by(id: foreign.id)).to be_present
    end
  end
end
