require "rails_helper"

RSpec.describe "API::Internal::Boards from_vocab_set", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let(:json_headers) { auth_headers.merge("Content-Type" => "application/json") }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  # A seeded robust-set ROOT board (Core 84) owned by the internal admin, with a
  # couple of tiles, stamped so Boards::RobustSets.find_root("core-84") resolves it.
  let!(:root) do
    board = create(:board, name: "Core 84", user: admin_user)
    2.times { create(:board_image, board: board, image: create(:image)) }
    Boards::RobustSets.mark_root!(board, "core-84")
    board
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  describe "POST /api/internal/boards/from_vocab_set" do
    context "without a valid bearer token" do
      it "returns 401" do
        post "/api/internal/boards/from_vocab_set", params: { slug: "core-84" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with a valid bearer token" do
      it "clones the seeded root into a new admin-owned board and returns 201" do
        expect {
          post "/api/internal/boards/from_vocab_set",
               params: { slug: "core-84" }.to_json,
               headers: json_headers
        }.to change(Board, :count).by(1)

        expect(response).to have_http_status(:created)

        body = JSON.parse(response.body)
        clone = Board.find(body["id"])

        expect(clone.id).not_to eq(root.id)
        expect(clone.user_id).to eq(User::DEFAULT_ADMIN_ID)
        expect(clone.name).to eq("Core 84")
        # Tiles copied from the source grid.
        expect(clone.board_images.count).to eq(root.board_images.count)
      end

      it "does not turn the clone into a second seeded robust-set root" do
        post "/api/internal/boards/from_vocab_set",
             params: { slug: "core-84" }.to_json,
             headers: json_headers

        clone = Board.find(JSON.parse(response.body)["id"])

        # The robust-set markers are stripped from the clone, so the lookup
        # still resolves the original seed root — not the fresh clone.
        expect(Boards::RobustSets.find_root("core-84")).to eq(root)
        expect(clone.settings["board_builder_robust"]).to be_nil
        expect(clone.settings["board_builder_robust_slug"]).to be_nil
      end

      it "honors an override name and applies tags" do
        post "/api/internal/boards/from_vocab_set",
             params: { slug: "core-84", name: "Core Words Poster", tags: ["marketing", "aac-kit"] }.to_json,
             headers: json_headers

        expect(response).to have_http_status(:created)
        clone = Board.find(JSON.parse(response.body)["id"])
        expect(clone.name).to eq("Core Words Poster")
        expect(clone.tags).to match_array(["marketing", "aac-kit"])
      end

      describe "board_slug + replace_existing_slug (stable marketing slugs)" do
        let(:kit_params) do
          {
            slug: "core-84",
            name: "MKT — Core Words Poster",
            tags: ["marketing", "aac-kit"],
            board_slug: "mkt-core-words-poster",
            replace_existing_slug: true,
          }
        end

        it "gives the clone the exact requested board_slug" do
          post "/api/internal/boards/from_vocab_set",
               params: kit_params.to_json,
               headers: json_headers

          expect(response).to have_http_status(:created)
          clone = Board.find(JSON.parse(response.body)["id"])
          expect(clone.slug).to eq("mkt-core-words-poster")
        end

        it "destroys the previous admin-owned marketing board holding that slug" do
          previous = create(:board, name: "MKT — Core Words Poster", slug: "mkt-core-words-poster",
                                    user: admin_user, tags: ["marketing", "aac-kit"])

          post "/api/internal/boards/from_vocab_set",
               params: kit_params.to_json,
               headers: json_headers

          expect(response).to have_http_status(:created)
          expect(Board.exists?(previous.id)).to be false
          clone = Board.find(JSON.parse(response.body)["id"])
          expect(clone.slug).to eq("mkt-core-words-poster")
        end

        it "leaves a non-marketing board holding that slug alone and suffixes instead" do
          bystander = create(:board, name: "User Board", slug: "mkt-core-words-poster",
                                     user: create(:user), tags: [])

          post "/api/internal/boards/from_vocab_set",
               params: kit_params.to_json,
               headers: json_headers

          expect(response).to have_http_status(:created)
          expect(Board.exists?(bystander.id)).to be true
          clone = Board.find(JSON.parse(response.body)["id"])
          expect(clone.slug).to start_with("mkt-core-words-poster-")
        end

        it "applies board_slug without destroying anything when the flag is absent" do
          previous = create(:board, name: "MKT — Core Words Poster", slug: "mkt-core-words-poster",
                                    user: admin_user, tags: ["marketing", "aac-kit"])

          post "/api/internal/boards/from_vocab_set",
               params: kit_params.except(:replace_existing_slug).to_json,
               headers: json_headers

          expect(response).to have_http_status(:created)
          expect(Board.exists?(previous.id)).to be true
          clone = Board.find(JSON.parse(response.body)["id"])
          expect(clone.slug).to start_with("mkt-core-words-poster-")
        end
      end

      it "returns 404 with an error body when the set is not seeded" do
        expect {
          post "/api/internal/boards/from_vocab_set",
               params: { slug: "core-999" }.to_json,
               headers: json_headers
        }.not_to change(Board, :count)

        expect(response).to have_http_status(:not_found)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("vocab_set_not_seeded")
        expect(body["slug"]).to eq("core-999")
      end
    end
  end
end
