require "rails_helper"

RSpec.describe "API::Internal::GeneratedBoards", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}", "Content-Type" => "application/json" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  describe "POST /api/internal/generated_boards" do
    context "without a valid bearer token" do
      it "returns 401" do
        post "/api/internal/generated_boards", params: { topic: "snacks" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with a valid bearer token" do
      it "returns 422 when topic is missing" do
        post "/api/internal/generated_boards",
             params: {}.to_json,
             headers: auth_headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("Topic is required")
      end

      it "creates a generated board owned by the default admin and enqueues GenerateFreeBoardJob" do
        expect {
          post "/api/internal/generated_boards",
               params: { topic: "snacks", age_range: "5-10", word_count: 9 }.to_json,
               headers: auth_headers
        }.to change(Board, :count).by(1)
         .and change(GenerateFreeBoardJob.jobs, :size).by(1)

        expect(response).to have_http_status(:created)

        body = JSON.parse(response.body)
        expect(body).to include("id", "name", "status")
        expect(body["status"]).to eq("generating")

        board = Board.find(body["id"])
        expect(board.user_id).to eq(User::DEFAULT_ADMIN_ID)
        expect(board.board_type).to eq("generated")
        expect(board.generated_token).to be_nil

        job = GenerateFreeBoardJob.jobs.last
        expect(job["args"]).to eq([board.id, "snacks", "5-10", 9])
      end
    end
  end
end
