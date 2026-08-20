require "rails_helper"

RSpec.describe "API::BoardImages text tiles", type: :request do
  let!(:user) { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:board) { create(:board, user: user) }
  let!(:board_image) { create(:board_image, board: board, image: create(:image, user: user, label: "more")) }

  let(:params) { { text: "more", font: "atkinson", text_color: "#1e3a8a", size: "l" } }

  def post_text_image(target = board_image, as: user, **overrides)
    post "/api/board_images/#{target.id}/create_text_image",
         params: params.merge(overrides),
         headers: auth_headers(as)
  end

  describe "authorization" do
    it "rejects an unauthenticated caller" do
      post "/api/board_images/#{board_image.id}/create_text_image", params: params
      expect(response).to have_http_status(:unauthorized)
    end

    it "404s a non-owner rather than revealing the tile" do
      post_text_image(as: other_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the free contract" do
    # The headline decision: this renders in-house, so it must never bill.
    # If this test is failing because a credit gate was added, the button copy
    # ("Free — no credits used") has to change with it.
    it "spends nothing" do
      expect { post_text_image }.not_to change { user.reload.tokens }
      expect(response).to have_http_status(:success)
    end

    it "does not create a credit transaction" do
      expect { post_text_image }.not_to change(CreditTransaction, :count)
    end
  end

  describe "a valid request" do
    it "enqueues the render and reports the tile as generating" do
      expect { post_text_image }.to change(RenderTextTileJob.jobs, :size).by(1)

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body)["status"]).to eq("generating")
    end

    it "persists the normalized config before the job runs" do
      post_text_image

      stored = board_image.reload.data["text_image"]
      expect(stored).to include("text" => "more", "font" => "atkinson", "size" => "l")
      expect(stored["text_color"]).to eq("#1e3a8a")
    end

    it "hides the tile label by default, since the picture is the word" do
      post_text_image
      expect(board_image.reload.data["hide_label"]).to be(true)
    end

    it "puts the label back when the box is unchecked" do
      post_text_image(hide_label: "false")
      expect(board_image.reload.data["hide_label"]).to be(false)
    end
  end

  describe "invalid input" do
    it "422s an unknown font rather than silently substituting one" do
      post_text_image(font: "Comic Sans")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_text_tile_options")
    end

    it "422s empty text" do
      post_text_image(text: "   ")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "does not enqueue anything it rejected" do
      expect { post_text_image(font: "nope") }.not_to change(RenderTextTileJob.jobs, :size)
    end
  end

  describe "the unchanged-render short circuit" do
    # Free and instant invites tweak-and-retry; an identical request must not
    # cost another headless Chrome.
    before do
      post_text_image
      RenderTextTileJob.jobs.clear
      board_image.reload
      # Stand in for the completed job.
      doc = board_image.image.docs.create!(source_type: Doc::SOURCE_TYPE_TEXT_TILE, user_id: user.id)
      board_image.update!(
        status: "complete",
        display_image_url: "https://cdn.example/text.png",
        data: board_image.data.merge(
          "text_image" => board_image.data["text_image"].merge("doc_id" => doc.id),
        ),
      )
    end

    it "skips the render when nothing about the picture changed" do
      expect { post_text_image }.not_to change(RenderTextTileJob.jobs, :size)

      expect(response).to have_http_status(:success)
      expect(board_image.reload.status).to eq("complete")
    end

    it "still re-renders when a paint option changes" do
      expect { post_text_image(text_color: "#ff0000") }.to change(RenderTextTileJob.jobs, :size).by(1)
      expect(board_image.reload.status).to eq("generating")
    end

    it "persists a hide_label change without repainting — it is not paint" do
      expect { post_text_image(hide_label: "false") }.not_to change(RenderTextTileJob.jobs, :size)
      expect(board_image.reload.data["hide_label"]).to be(false)
    end

    it "re-renders when the doc behind the stored config is gone" do
      Doc.find(board_image.reload.data.dig("text_image", "doc_id")).destroy

      expect { post_text_image }.to change(RenderTextTileJob.jobs, :size).by(1)
    end
  end

  describe "POST /api/board_images/create_text_images (bulk)" do
    let!(:second_tile) do
      create(:board_image, board: board, image: create(:image, user: user, label: "want"))
    end

    def post_bulk(ids: nil, as: user, board_id: board.id)
      post "/api/board_images/create_text_images",
           params: { board_id: board_id, board_image_ids: ids || [board_image.id, second_tile.id] },
           headers: auth_headers(as)
    end

    it "rejects an unauthenticated caller" do
      post "/api/board_images/create_text_images",
           params: { board_id: board.id, board_image_ids: [board_image.id] }
      expect(response).to have_http_status(:unauthorized)
    end

    it "renders one tile per selection and reports them queued" do
      expect { post_bulk }.to change(RenderTextTilesJob.jobs, :size).by(1)
      expect(RenderTextTilesJob.jobs.last["args"].first.map(&:first))
        .to contain_exactly(board_image.id, second_tile.id)

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body).to include("queued" => 2, "unlabeled" => 0, "unchanged" => 0)
      expect(body["board"]).to be_present
    end

    it "renders each tile's OWN label, not one shared string" do
      post_bulk

      expect(board_image.reload.data.dig("text_image", "text")).to eq("more")
      expect(second_tile.reload.data.dig("text_image", "text")).to eq("want")
    end

    it "hides the label — the picture is the word" do
      post_bulk
      expect(board_image.reload.data["hide_label"]).to be(true)
    end

    it "renders on a transparent background so the tile's colour still shows" do
      board_image.update!(bg_color: "blue")
      post_bulk

      stored = board_image.reload.data["text_image"]
      expect(stored["bg_color"]).to eq("transparent")
      # Derived from the tile's own background: there is no preview on this
      # path, so a near-black default on a dark tile would go unnoticed.
      expect(stored["text_color"]).to eq(ColorHelper.text_hex_for(board_image.bg_hex))
    end

    it "skips a tile with no text instead of failing the batch" do
      second_tile.update_columns(label: nil, display_label: nil)

      expect { post_bulk }.to change(RenderTextTilesJob.jobs, :size).by(1)

      expect(RenderTextTilesJob.jobs.last["args"].first.map(&:first)).to eq([board_image.id])
      expect(JSON.parse(response.body)).to include("queued" => 1, "unlabeled" => 1)
      expect(second_tile.reload.data&.dig("text_image")).to be_nil
    end

    it "does not re-render a tile that already shows this exact picture" do
      post_bulk
      RenderTextTilesJob.jobs.clear
      [board_image, second_tile].each do |tile|
        tile.reload
        doc = tile.image.docs.create!(source_type: Doc::SOURCE_TYPE_TEXT_TILE, user_id: user.id)
        tile.update!(
          status: "complete",
          display_image_url: "https://cdn.example/text.png",
          data: tile.data.merge("text_image" => tile.data["text_image"].merge("doc_id" => doc.id)),
        )
      end

      expect { post_bulk }.not_to change(RenderTextTilesJob.jobs, :size)
      expect(JSON.parse(response.body)).to include("queued" => 0, "unchanged" => 2)
    end

    it "ignores an id that is not on this board" do
      # Deliberately someone else's tile: the ids come from the client, and
      # scoping to @board.board_images is the only thing keeping them honest.
      stranger = create(
        :board_image,
        board: create(:board, user: other_user),
        image: create(:image, user: other_user, label: "stop"),
      )

      expect { post_bulk(ids: [board_image.id, stranger.id]) }
        .to change(RenderTextTilesJob.jobs, :size).by(1)
      expect(RenderTextTilesJob.jobs.last["args"].first.map(&:first)).to eq([board_image.id])

      expect(JSON.parse(response.body)).to include("queued" => 1)
      expect(stranger.reload.data&.dig("text_image")).to be_nil
    end

    it "422s when no tiles were given" do
      # Rack turns an empty array into [""], so this also pins the blank-reject.
      post_bulk(ids: [])
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "422s an unknown board" do
      post_bulk(board_id: 0)
      expect(response).to have_http_status(:unprocessable_content)
    end

    # Same headline as the single-tile path: this renders in-house, so bulk
    # must not become the place a credit gate sneaks in.
    it "spends nothing" do
      expect { post_bulk }.not_to change(CreditTransaction, :count)
      expect(user.reload.tokens).to eq(user.tokens)
    end
  end
end
