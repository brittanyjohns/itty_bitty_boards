require "rails_helper"

RSpec.describe "API::Boards#pdf", type: :request do
  let!(:user)  { create(:user) }
  let!(:board) { create(:board, user: user, name: "PDF Board") }

  before do
    fake_grover = instance_double(Grover, to_pdf: "%PDF-fake")
    allow(Grover).to receive(:new).and_return(fake_grover)
    allow_any_instance_of(API::BoardsController)
      .to receive(:render_to_string).and_return("<html></html>")
  end

  describe "GET /api/boards/:id/pdf" do
    it "defaults to color with QR code included" do
      expect(Boards::RenderAssetData).to receive(:new).with(
        hash_including(board: board, hide_colors: false, include_qr: true),
      ).and_call_original

      get "/api/boards/#{board.id}/pdf", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("#{board.slug}-board.pdf")
    end

    it "renders black-and-white when bw=1" do
      expect(Boards::RenderAssetData).to receive(:new).with(
        hash_including(hide_colors: true, include_qr: true),
      ).and_call_original

      get "/api/boards/#{board.id}/pdf", params: { bw: "1" }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("#{board.slug}-board-bw.pdf")
    end

    it "omits the QR code when qr=0" do
      expect(Boards::RenderAssetData).to receive(:new).with(
        hash_including(include_qr: false),
      ).and_call_original

      get "/api/boards/#{board.id}/pdf", params: { qr: "0" }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
    end

    it "does not cache the attachment when a non-default variant is requested" do
      expect {
        get "/api/boards/#{board.id}/pdf", params: { bw: "1" }, headers: auth_headers(user)
      }.not_to change { board.reload.pdf_file.attached? }.from(false)
    end

    it "caches the attachment on the default variant" do
      expect {
        get "/api/boards/#{board.id}/pdf", headers: auth_headers(user)
      }.to change { board.reload.pdf_file.attached? }.from(false).to(true)
    end
  end

  # `pdf` is in the controller's `skip_before_action :authenticate_token!` list
  # because anonymous download of genuinely PUBLIC boards backs the free-boards
  # landing page. That makes the action's own `viewable_by?` guard the only
  # thing standing between an incrementing integer and every private board's
  # complete contents — tile labels, symbols, and a board name that routinely
  # carries a child's first name.
  describe "authorization" do
    let!(:public_board)  { create(:board, user: user, name: "Public PDF Board", published: true) }
    let!(:other_user)    { create(:user) }

    it "lets an anonymous caller download a published board" do
      get "/api/boards/#{public_board.id}/pdf"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
    end

    it "404s an anonymous caller asking for a private board" do
      get "/api/boards/#{board.id}/pdf"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("Board not found")
    end

    it "lets the owner download their own private board" do
      get "/api/boards/#{board.id}/pdf", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
    end

    it "lets a communicator download a private board belonging to their own account" do
      communicator = create(:child_account, user: user)

      get "/api/boards/#{board.id}/pdf", headers: auth_headers(communicator)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
    end

    it "404s a communicator asking for a private board on someone else's account" do
      communicator = create(:child_account, user: other_user)

      get "/api/boards/#{board.id}/pdf", headers: auth_headers(communicator)

      expect(response).to have_http_status(:not_found)
    end

    it "404s a signed-in non-owner asking for someone else's private board" do
      get "/api/boards/#{board.id}/pdf", headers: auth_headers(other_user)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("Board not found")
    end
  end
end
