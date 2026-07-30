require "rails_helper"

RSpec.describe "API::BoardExports", type: :request do
  let(:user)     { create(:user) }
  let(:stranger) { create(:user) }
  let!(:board)   { create(:board, user: user, name: "Snacks") }

  before do
    allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/i.png")
    allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
  end

  describe "POST /api/boards/:id/export_package" do
    it "returns 401 when unauthenticated" do
      post "/api/boards/#{board.id}/export_package"
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a queued export and enqueues the job" do
      expect {
        post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      }.to change(BoardExport, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["status"]).to eq("queued")
    end

    it "returns 404 for a board the user may not read" do
      post "/api/boards/#{board.id}/export_package", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/board_exports/:id" do
    let!(:record) { BoardExport.create!(user: user, exportable: board) }

    it "returns the export status to its owner" do
      get "/api/board_exports/#{record.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("queued")
    end

    it "returns 404 to anyone else" do
      get "/api/board_exports/#{record.id}", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "ExportBoardPackageJob" do
    let!(:record) { BoardExport.create!(user: user, exportable: board) }

    it "attaches a package and completes" do
      ExportBoardPackageJob.new.perform(record.id)
      record.reload

      expect(record.status).to eq("completed")
      expect(record.file).to be_attached
      expect(record.settings["exported_to_obf"]).to be_present
    end

    it "records a failure instead of raising" do
      allow(Boards::ExportScope).to receive(:for_board).and_raise(StandardError, "kaboom")

      expect { ExportBoardPackageJob.new.perform(record.id) }.not_to raise_error
      expect(record.reload.status).to eq("failed")
      expect(record.error_message).to be_present
    end
  end
end
