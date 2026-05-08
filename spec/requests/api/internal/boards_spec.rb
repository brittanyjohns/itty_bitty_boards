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
