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

    # The free-boards landing page lists `Board.public_boards` and downloads each
    # one anonymously (`downloadPublicBoardPdf`), with the email capture enforced
    # in the browser only — the endpoint knows nothing about a lead. So the
    # guarantee this guard has to keep is about the SCOPE, not about a board that
    # happens to be published: everything `free_download_boards` advertises must
    # still come back 200 with no credentials.
    it "keeps every board in the free-download scope anonymously downloadable" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) ||
              create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      listed = create(:board, user: admin, name: "Free Core Board", published: true, predefined: true)

      # Guards the premise: if the scope stops including this board, this spec
      # is no longer testing what it claims to.
      expect(Board.public_boards).to include(listed)

      get "/api/boards/#{listed.id}/pdf"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
    end

    # The end-to-end version of the guarantee above: whatever the free-boards
    # page is told it can offer, it can actually fetch — both hops anonymous,
    # exactly as a logged-out visitor makes them.
    it "downloads every board the free-download listing advertises, all anonymous" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) ||
              create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      create(:board, user: admin, name: "Free Core Board", published: true, predefined: true)
      create(:board, user: admin, name: "Free Snack Board", published: true, predefined: true)

      get "/api/free_download_boards"
      expect(response).to have_http_status(:ok)

      listed = JSON.parse(response.body)["boards"]
      expect(listed).to be_present

      listed.each do |board|
        get "/api/boards/#{board["id"]}/pdf"

        expect(response).to have_http_status(:ok),
          "#{board["name"].inspect} is advertised on the free-boards page but 404s anonymously"
        expect(response.content_type).to start_with("application/pdf")
      end
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
