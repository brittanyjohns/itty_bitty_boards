require "rails_helper"

RSpec.describe "API::ClinicianApplications", type: :request do
  let(:user) { FactoryBot.create(:user) }

  let(:valid_params) do
    {
      clinician_application: {
        full_name: "Alex Rivera",
        credential_type: "slp",
        license_id: "SLP-12345",
        workplace: "Sunrise Elementary",
      },
    }
  end

  describe "POST /api/clinician_applications" do
    it "creates a pending application and emails a confirmation" do
      expect(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))

      expect {
        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)
      }.to change { user.clinician_applications.count }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["application"]["status"]).to eq("pending")
      expect(body["application"]["credential_type"]).to eq("slp")
    end

    it "allows only one pending application at a time" do
      allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))
      post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      expect {
        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)
      }.not_to change { user.clinician_applications.count }
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("application_pending")
    end

    it "requires authentication (401)" do
      post "/api/clinician_applications", params: valid_params
      expect(response).to have_http_status(:unauthorized)
    end

    it "422s on invalid params (missing full_name)" do
      bad = { clinician_application: { credential_type: "slp" } }
      post "/api/clinician_applications", params: bad, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /api/clinician_applications/mine" do
    it "returns the user's latest application" do
      app = user.clinician_applications.create!(full_name: "A", credential_type: "ot", status: "denied")
      get "/api/clinician_applications/mine", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["application"]["id"]).to eq(app.id)
    end

    it "returns null when the user has no application" do
      get "/api/clinician_applications/mine", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["application"]).to be_nil
    end
  end
end
