require "rails_helper"

RSpec.describe "API::Internal::Boards#export_pdf", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let!(:board) { create(:board, name: "PDF Board", user: admin_user) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)

    # Bypass actual Chromium / Grover rendering
    fake_grover = instance_double(Grover, to_pdf: "%PDF-fake")
    allow(Grover).to receive(:new).and_return(fake_grover)

    # Bypass the heavy template render — the action's only template-related
    # responsibility is to feed render_data into render_to_string.
    allow_any_instance_of(API::Internal::BoardsController)
      .to receive(:render_to_string).and_return("<html></html>")
  end

  describe "GET /api/internal/boards/:id/export.pdf" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/boards/#{board.id}/export.pdf"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns a PDF with the QR code when qr_code=true and a qr_target_url is provided" do
      expect(Boards::RenderAssetData).to receive(:new).with(
        hash_including(
          board: board,
          include_qr: true,
          qr_target_url: "https://example.com/claim/abc",
        ),
      ).and_call_original

      get "/api/internal/boards/#{board.id}/export.pdf",
          params: { qr_code: "true", qr_target_url: "https://example.com/claim/abc" },
          headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.body).to start_with("%PDF")
    end

    it "renders the shared print template and pdf layout by default" do
      expect_any_instance_of(API::Internal::BoardsController)
        .to receive(:render_to_string)
        .with(hash_including(template: "api/boards/print", layout: "pdf"))
        .and_return("<html></html>")

      get "/api/internal/boards/#{board.id}/export.pdf", headers: auth_headers

      expect(response).to have_http_status(:ok)
    end

    it "renders the marketing template and layout when style=marketing" do
      expect_any_instance_of(API::Internal::BoardsController)
        .to receive(:render_to_string)
        .with(hash_including(template: "api/boards/print_marketing", layout: "pdf_marketing"))
        .and_return("<html></html>")

      get "/api/internal/boards/#{board.id}/export.pdf",
          params: { style: "marketing" },
          headers: auth_headers

      expect(response).to have_http_status(:ok)
    end

    it "ignores unknown style values and falls back to the shared template" do
      expect_any_instance_of(API::Internal::BoardsController)
        .to receive(:render_to_string)
        .with(hash_including(template: "api/boards/print", layout: "pdf"))
        .and_return("<html></html>")

      get "/api/internal/boards/#{board.id}/export.pdf",
          params: { style: "fancy" },
          headers: auth_headers

      expect(response).to have_http_status(:ok)
    end

    context "with real template rendering (ERB smoke test, Grover still stubbed)" do
      before do
        allow_any_instance_of(API::Internal::BoardsController)
          .to receive(:render_to_string).and_call_original
      end

      it "renders the shared print template without error" do
        get "/api/internal/boards/#{board.id}/export.pdf", headers: auth_headers
        expect(response).to have_http_status(:ok)
      end

      it "renders the marketing template without error" do
        get "/api/internal/boards/#{board.id}/export.pdf",
            params: { style: "marketing", qr_code: "true", qr_target_url: "https://app.speakanyway.com/pb/test" },
            headers: auth_headers
        expect(response).to have_http_status(:ok)
      end
    end

    it "omits the QR code when qr_code is not true" do
      expect(Boards::RenderAssetData).to receive(:new).with(
        hash_including(include_qr: false),
      ).and_call_original

      get "/api/internal/boards/#{board.id}/export.pdf",
          params: { qr_code: "false" },
          headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
    end
  end
end
