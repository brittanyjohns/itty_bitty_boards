require "rails_helper"

RSpec.describe "Admin::ClinicianApplications (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let_it_be(:admin) { create(:admin_user) }

  let(:applicant) { create(:user, email: "clin@example.com", plan_type: "free") }
  let!(:application) do
    applicant.clinician_applications.create!(full_name: "Sam Lee", credential_type: "slp", status: "pending")
  end

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "GET /admin/clinician_applications" do
    it "renders pending applications by default for an admin" do
      sign_in admin
      get admin_dashboard_clinician_applications_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("clin@example.com")
      expect(response.body).to include("Sam Lee")
    end

    it "filters by status" do
      sign_in admin
      other = create(:user).clinician_applications.create!(full_name: "Approved One", credential_type: "ot", status: "approved")
      get admin_dashboard_clinician_applications_path(status: "approved")
      expect(response.body).to include("Approved One")
      expect(response.body).not_to include("clin@example.com")
    end

    it "redirects a non-admin away" do
      sign_in create(:user)
      get admin_dashboard_clinician_applications_path
      expect(response).to have_http_status(:redirect)
    end
  end

  describe "POST approve" do
    it "flips the applicant to clinician, grants credits, and redirects with a notice" do
      sign_in admin
      expect(ClinicianMailer).to receive(:approved_email).and_return(double(deliver_later: true))

      post approve_admin_dashboard_clinician_application_path(application)

      expect(response).to redirect_to(admin_dashboard_clinician_applications_path(status: nil))
      applicant.reload
      expect(applicant.plan_type).to eq("clinician")
      expect(applicant.plan_credits_balance).to eq(400)
      expect(application.reload.status).to eq("approved")
      expect(application.reviewed_by_id).to eq(admin.id)
      expect(flash[:notice]).to be_present
    end

    it "does not let a non-admin approve" do
      sign_in create(:user)
      post approve_admin_dashboard_clinician_application_path(application)
      expect(response).to have_http_status(:redirect)
      expect(applicant.reload.plan_type).to eq("free")
    end
  end

  describe "POST deny" do
    it "denies with a note and redirects with a notice" do
      sign_in admin
      expect(ClinicianMailer).to receive(:denied_email).and_return(double(deliver_later: true))

      post deny_admin_dashboard_clinician_application_path(application), params: { notes: "Could not verify." }

      expect(response).to have_http_status(:redirect)
      expect(application.reload.status).to eq("denied")
      expect(application.notes).to eq("Could not verify.")
      expect(applicant.reload.plan_type).to eq("free")
    end
  end
end
