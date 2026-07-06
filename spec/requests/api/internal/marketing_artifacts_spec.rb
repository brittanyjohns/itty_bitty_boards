require "rails_helper"

RSpec.describe "API::Internal::MarketingArtifacts", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)

    # Bypass actual Chromium / Grover rendering.
    fake_grover = instance_double(Grover, to_pdf: "%PDF-fake-name-tags")
    allow(Grover).to receive(:new).and_return(fake_grover)
  end

  describe "GET /api/internal/marketing_artifacts/name_tag.pdf" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/marketing_artifacts/name_tag.pdf"
      expect(response).to have_http_status(:unauthorized)
    end

    it "streams a generic name-tag sheet PDF pointing the QR at the given target" do
      expect(Marketing::NameTagSheet).to receive(:new).with(
        hash_including(qr_target_url: "https://speakanyway.com/classroom?utm_content=name_tag"),
      ).and_call_original

      get "/api/internal/marketing_artifacts/name_tag.pdf",
          params: { qr_target_url: "https://speakanyway.com/classroom?utm_content=name_tag" },
          headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.body).to start_with("%PDF")
    end
  end
end
