require "rails_helper"

RSpec.describe "API::Internal::Boards", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  describe "POST /api/internal/boards" do
    context "without a valid bearer token" do
      it "returns 401" do
        post "/api/internal/boards", params: { board: { name: "Nope" } }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with a valid bearer token" do
      it "creates a board and returns 201" do
        expect {
          post "/api/internal/boards",
               params: { board: { name: "Internal Board" } }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")
        }.to change(Board, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(Board.last.user_id).to eq(User::DEFAULT_ADMIN_ID)
      end

      it "does not enqueue GenerateBoardJob when no word_list is given" do
        expect {
          post "/api/internal/boards",
               params: { board: { name: "Quiet Board" } }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")
        }.not_to change(GenerateBoardJob.jobs, :size)

        expect(response).to have_http_status(:created)
      end

      it "enqueues GenerateBoardJob with the word_list when one is given" do
        word_list = ["apple", "banana"]

        expect {
          post "/api/internal/boards",
               params: { board: { name: "Word List Board" }, word_list: word_list }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")
        }.to change(GenerateBoardJob.jobs, :size).by(1)

        expect(response).to have_http_status(:created)

        job = GenerateBoardJob.jobs.last
        expect(job["args"][0]).to eq(Board.last.id)
        expect(job["args"][1]).to eq("default")
        expect(job["args"][2]).to eq({ "word_list" => word_list })
      end

      it "enqueues GenerateBoardJob with topic/age_range/word_count for scenario creation_type" do
        expect {
          post "/api/internal/boards",
               params: {
                 board: { name: "Scenario Board" },
                 board_creation_type: "scenario",
                 topic: "ordering coffee",
                 age_range: "10-15",
                 word_count: 16,
               }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")
        }.to change(GenerateBoardJob.jobs, :size).by(1)

        expect(response).to have_http_status(:created)
        expect(Board.last.board_type).to eq("scenario")

        job = GenerateBoardJob.jobs.last
        expect(job["args"][1]).to eq("scenario")
        expect(job["args"][2]).to eq({
          "topic" => "ordering coffee",
          "age_range" => "10-15",
          "word_count" => 16,
        })
      end

      it "forwards starting_phrase_or_word and word_list for predictive creation_type" do
        expect {
          post "/api/internal/boards",
               params: {
                 board: { name: "After 'I want'" },
                 board_creation_type: "predictive",
                 starting_phrase_or_word: "I want",
                 word_count: 9,
               }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")
        }.to change(GenerateBoardJob.jobs, :size).by(1)

        expect(response).to have_http_status(:created)

        job = GenerateBoardJob.jobs.last
        expect(job["args"][1]).to eq("predictive")
        expect(job["args"][2]).to eq({
          "word_list" => [],
          "starting_phrase_or_word" => "I want",
          "word_count" => 9,
        })
      end

      describe "screen-column handling on create" do
        it "applies model defaults when no column params are sent" do
          post "/api/internal/boards",
               params: { board: { name: "Defaults" } }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")

          expect(response).to have_http_status(:created)
          board = Board.last
          # Board#set_screen_sizes only fills nil; verifying defaults landed
          # confirms the controller no longer coerces missing params to 0.
          expect(board.small_screen_columns).to be > 0
          expect(board.medium_screen_columns).to be > 0
          expect(board.large_screen_columns).to be > 0
        end

        it "honors large_screen_columns when provided" do
          post "/api/internal/boards",
               params: { board: { name: "Six Wide", large_screen_columns: 6 } }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")

          expect(response).to have_http_status(:created)
          expect(Board.last.large_screen_columns).to eq(6)
        end

        it "honors all three column params when provided" do
          post "/api/internal/boards",
               params: {
                 board: {
                   name: "All Columns",
                   small_screen_columns: 2,
                   medium_screen_columns: 4,
                   large_screen_columns: 6,
                 },
               }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")

          expect(response).to have_http_status(:created)
          board = Board.last
          expect(board.small_screen_columns).to eq(2)
          expect(board.medium_screen_columns).to eq(4)
          expect(board.large_screen_columns).to eq(6)
        end
      end

      it "enqueues GenerateBoardJob with word_count for other creation_types" do
        expect {
          post "/api/internal/boards",
               params: {
                 board: { name: "Other Board" },
                 board_creation_type: "ai_generated",
                 word_count: 24,
               }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")
        }.to change(GenerateBoardJob.jobs, :size).by(1)

        expect(response).to have_http_status(:created)

        job = GenerateBoardJob.jobs.last
        expect(job["args"][1]).to eq("ai_generated")
        expect(job["args"][2]).to eq({ "word_count" => 24 })
      end

      describe "replace_existing_slug (stable marketing slugs)" do
        let(:create_params) do
          {
            board: { name: "MKT — Story Time", slug: "mkt-storytime-board", tags: ["marketing", "aac-kit"] },
            replace_existing_slug: true,
          }
        end

        it "destroys the previous admin-owned marketing board and takes its exact slug" do
          previous = create(:board, name: "MKT — Old Story Time", slug: "mkt-storytime-board",
                                    user: admin_user, tags: ["marketing", "aac-kit"])

          post "/api/internal/boards",
               params: create_params.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")

          expect(response).to have_http_status(:created)
          expect(Board.exists?(previous.id)).to be false
          expect(Board.last.slug).to eq("mkt-storytime-board")
        end

        it "leaves a non-marketing board with that slug alone and suffixes the new slug" do
          bystander = create(:board, name: "User Board", slug: "mkt-storytime-board",
                                     user: create(:user), tags: [])

          post "/api/internal/boards",
               params: create_params.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")

          expect(response).to have_http_status(:created)
          expect(Board.exists?(bystander.id)).to be true
          new_board = Board.last
          expect(new_board.slug).not_to eq("mkt-storytime-board")
          expect(new_board.slug).to start_with("mkt-storytime-board-")
        end

        it "leaves an admin-owned but untagged board with that slug alone" do
          untagged = create(:board, name: "Admin Board", slug: "mkt-storytime-board",
                                    user: admin_user, tags: [])

          post "/api/internal/boards",
               params: create_params.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")

          expect(response).to have_http_status(:created)
          expect(Board.exists?(untagged.id)).to be true
          expect(Board.last.slug).to start_with("mkt-storytime-board-")
        end

        it "does not destroy anything when the flag is absent" do
          previous = create(:board, name: "MKT — Old Story Time", slug: "mkt-storytime-board",
                                    user: admin_user, tags: ["marketing", "aac-kit"])

          post "/api/internal/boards",
               params: create_params.except(:replace_existing_slug).to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")

          expect(response).to have_http_status(:created)
          expect(Board.exists?(previous.id)).to be true
          expect(Board.last.slug).to start_with("mkt-storytime-board-")
        end
      end
    end
  end

  describe "GET /api/internal/boards/:id" do
    let!(:board) { create(:board, name: "Show Me", user: admin_user) }

    context "without a valid bearer token" do
      it "returns 401" do
        get "/api/internal/boards/#{board.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with a valid bearer token" do
      it "returns the board as JSON" do
        get "/api/internal/boards/#{board.id}", headers: auth_headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["id"]).to eq(board.id)
        expect(body["name"]).to eq("Show Me")
      end

      it "returns 404 when the board does not exist" do
        get "/api/internal/boards/0", headers: auth_headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "PATCH /api/internal/boards/:id" do
    let!(:board) { create(:board, name: "Old Name", user: admin_user) }

    context "without a valid bearer token" do
      it "returns 401" do
        patch "/api/internal/boards/#{board.id}", params: { board: { name: "New" } }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with a valid bearer token" do
      it "renames the board and returns 200" do
        patch "/api/internal/boards/#{board.id}",
              params: { board: { name: "New Name" } }.to_json,
              headers: auth_headers.merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:ok)
        expect(board.reload.name).to eq("New Name")
      end
    end
  end
end
