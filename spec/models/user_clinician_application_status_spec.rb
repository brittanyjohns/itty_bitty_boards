require "rails_helper"

RSpec.describe User, "clinician application status" do
  let(:user) { FactoryBot.create(:user) }

  def apply!(status, created_at: Time.current)
    user.clinician_applications.create!(
      full_name: "Alex Rivera",
      credential_type: "slp",
      license_id: "SLP-12345",
      workplace: "Sunrise Elementary",
      status: status,
      created_at: created_at,
    )
  end

  describe "#clinician_application_status" do
    it "is nil for a user who has never applied" do
      expect(user.clinician_application_status).to be_nil
    end

    it "reports a pending application" do
      apply!(ClinicianApplication::PENDING)

      expect(user.clinician_application_status).to eq("pending")
    end

    # A denied applicant may re-apply, so "most recent" — not "any" — is what
    # the dashboard notice keys off. Reading the older denial would park a
    # re-applicant on the wrong message.
    it "reports the most recent application when the user re-applied" do
      apply!(ClinicianApplication::DENIED, created_at: 1.month.ago)
      apply!(ClinicianApplication::PENDING)

      expect(user.clinician_application_status).to eq("pending")
    end
  end

  describe "#api_view" do
    it "omits nothing but reports nil when the user has never applied" do
      expect(user.api_view).to have_key(:clinician_application_status)
      expect(user.api_view[:clinician_application_status]).to be_nil
    end

    it "exposes the pending status so the dashboard can show the review notice" do
      apply!(ClinicianApplication::PENDING)

      expect(user.api_view[:clinician_application_status]).to eq("pending")
    end
  end
end
