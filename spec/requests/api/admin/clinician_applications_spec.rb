require "rails_helper"

RSpec.describe "API::Admin::ClinicianApplications", type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:applicant) { FactoryBot.create(:user, plan_type: "free") }
  let!(:application) do
    applicant.clinician_applications.create!(
      full_name: "Sam Lee", credential_type: "slp", status: "pending",
    )
  end

  describe "POST approve" do
    it "flips the applicant to clinician, grants credits, and emails them" do
      expect(ClinicianMailer).to receive(:approved_email).and_return(double(deliver_later: true))

      post "/api/admin/clinician_applications/#{application.id}/approve", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      applicant.reload
      expect(applicant.plan_type).to eq("clinician")
      expect(applicant.paid_plan?).to be(true)
      expect(applicant.settings["paid_communicator_limit"]).to eq(2)
      expect(applicant.plan_credits_balance).to eq(400)
      expect(application.reload.status).to eq("approved")
      expect(application.reviewed_by_id).to eq(admin.id)
    end

    it "is forbidden (403) for a signed-in non-admin" do
      other = FactoryBot.create(:user)
      post "/api/admin/clinician_applications/#{application.id}/approve", headers: auth_headers(other)
      expect(response).to have_http_status(:forbidden)
      expect(applicant.reload.plan_type).to eq("free")
    end

    it "is unauthorized (401) without a token" do
      post "/api/admin/clinician_applications/#{application.id}/approve"
      expect(response).to have_http_status(:unauthorized)
    end

    it "422s when the application is not pending" do
      application.update!(status: "denied")
      post "/api/admin/clinician_applications/#{application.id}/approve", headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST deny" do
    it "marks the application denied with a note and emails the applicant" do
      expect(ClinicianMailer).to receive(:denied_email).and_return(double(deliver_later: true))

      post "/api/admin/clinician_applications/#{application.id}/deny",
           params: { notes: "Could not verify license." },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(application.reload.status).to eq("denied")
      expect(application.notes).to eq("Could not verify license.")
      expect(applicant.reload.plan_type).to eq("free")
    end

    it "is forbidden (403) for a non-admin" do
      other = FactoryBot.create(:user)
      post "/api/admin/clinician_applications/#{application.id}/deny", headers: auth_headers(other)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET index" do
    it "lists pending applications for admins" do
      get "/api/admin/clinician_applications", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body)["applications"].map { |a| a["id"] }
      expect(ids).to include(application.id)
    end
  end
end
