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

    it "returns 409 when the user already has a queued export in flight" do
      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq("export_in_progress")
    end

    it "allows a new export once the prior one has completed" do
      first = BoardExport.create!(user: user, exportable: board, status: "completed")

      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:created)
    end
  end

  describe "POST /api/board_groups/:id/export_package" do
    let!(:board_group) { create(:board_group, user: user) }

    it "creates a queued export and enqueues the job for the owner" do
      expect {
        post "/api/board_groups/#{board_group.id}/export_package", headers: auth_headers(user)
      }.to change(BoardExport, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("queued")
      expect(BoardExport.last.exportable).to eq(board_group)
    end

    it "does not create an export for a user not authorized to read the board group" do
      expect {
        post "/api/board_groups/#{board_group.id}/export_package", headers: auth_headers(stranger)
      }.not_to change(BoardExport, :count)

      expect(response).not_to have_http_status(:success)
    end

    it "returns 409 when the user already has a queued export for a different board group" do
      post "/api/board_groups/#{board_group.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      other_group = create(:board_group, user: user)
      post "/api/board_groups/#{other_group.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:conflict)
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

    it "surfaces the packager's own message on TooLarge, not the generic failure text" do
      allow_any_instance_of(Boards::ObzPackager).to receive(:call)
        .and_raise(Boards::ObzPackager::TooLarge, "too big")

      expect { ExportBoardPackageJob.new.perform(record.id) }.not_to raise_error
      record.reload
      expect(record.status).to eq("failed")
      expect(record.error_message).to eq("too big")
    end

    it "fails cleanly instead of packaging a structurally empty export scope" do
      empty_group = create(:board_group, user: user)
      empty_record = BoardExport.create!(user: user, exportable: empty_group)

      expect { ExportBoardPackageJob.new.perform(empty_record.id) }.not_to raise_error
      empty_record.reload
      expect(empty_record.status).to eq("failed")
      expect(empty_record.error_message).to be_present
    end
  end

  describe "GET /api/board_exports/:id/download" do
    it "404s a queued (not yet completed) export" do
      record = BoardExport.create!(user: user, exportable: board)
      get "/api/board_exports/#{record.id}/download", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "404s a completed export with no file attached" do
      record = BoardExport.create!(user: user, exportable: board, status: "completed")
      get "/api/board_exports/#{record.id}/download", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "returns the .obz bytes for a completed, attached export" do
      record = BoardExport.create!(user: user, exportable: board)
      ExportBoardPackageJob.new.perform(record.id)
      record.reload

      get "/api/board_exports/#{record.id}/download", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("application/zip")
    end

    it "404s a stranger's attempt to download someone else's completed export" do
      record = BoardExport.create!(user: user, exportable: board)
      ExportBoardPackageJob.new.perform(record.id)
      record.reload

      get "/api/board_exports/#{record.id}/download", headers: auth_headers(stranger)

      expect(response).to have_http_status(:not_found)
    end
  end
end
