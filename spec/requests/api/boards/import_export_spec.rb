require "rails_helper"

RSpec.describe "API::Boards OBF/OBZ import + export", type: :request do
  let(:user) { create(:user) }

  describe "POST /api/boards/import_obf" do
    let(:obz_path) { Rails.root.join("spec/data/simple.obz") }
    let(:obz_upload) { Rack::Test::UploadedFile.new(obz_path, "application/zip") }

    it "returns 401 when unauthenticated" do
      post "/api/boards/import_obf", params: { file: obz_upload }
      expect(response).to have_http_status(:unauthorized)
    end

    it "imports a .obz file and creates a board for the user" do
      expect {
        post "/api/boards/import_obf",
             params: { file: obz_upload },
             headers: auth_headers(user)
      }.to change { user.boards.count }.by(1)
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
      expect(body["root_board_id"]).to be_present
    end

    it "returns 422 for an unsupported extension" do
      txt = Rack::Test::UploadedFile.new(
        StringIO.new("not a board"), "text/plain",
        original_filename: "notes.txt",
      )
      post "/api/boards/import_obf",
           params: { file: txt },
           headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/unsupported/i)
    end
  end

  describe "GET /api/boards/:id/download_obf" do
    let!(:board) do
      b = create(:board, user: user, name: "Exportable Board")
      img = create(:image, label: "hi", user: user)
      b.board_images.create!(image_id: img.id, voice: "polly:kevin",
                             position: 0, skip_create_voice_audio: true)
      b
    end

    before do
      allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/img.png")
      allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
    end

    it "returns a downloadable OBF JSON document" do
      get "/api/boards/#{board.id}/download_obf", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(response.headers["Content-Disposition"]).to include('filename="board.obf"')
      body = JSON.parse(response.body)
      expect(body["format"]).to eq("open-board-0.1")
      expect(body["name"]).to eq("Exportable Board")
      expect(body["buttons"].size).to eq(1)
    end
  end
end
