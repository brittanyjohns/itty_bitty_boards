require "rails_helper"

RSpec.describe ClinicianApplications::Reviewer do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:applicant) { FactoryBot.create(:user) }

  let(:application) do
    ClinicianApplication.create!(
      user: applicant,
      status: ClinicianApplication::PENDING,
      full_name: "Sam Lee",
      credential_type: "slp",
    )
  end

  # The applicant email is a notification, not part of the review: it is enqueued
  # after the transaction has committed and the credits have been granted, so a
  # Redis/ActiveJob blip must not tell the admin the review failed. It used to —
  # and the retry then hit the not_pending guard.
  def failing_delivery
    double.tap { |d| allow(d).to receive(:deliver_later).and_raise(Redis::CannotConnectError) }
  end

  describe ".approve!" do
    it "still reports success when the applicant email can't be enqueued" do
      allow(ClinicianMailer).to receive(:approved_email).and_return(failing_delivery)

      result = described_class.approve!(application, admin: admin)

      expect(result.ok).to be true
      expect(application.reload).to be_approved
      expect(applicant.reload.plan_type).to eq("clinician")
    end

    it "refuses an application that has already been reviewed" do
      application.update!(status: ClinicianApplication::DENIED)

      result = described_class.approve!(application, admin: admin)

      expect(result.ok).to be false
      expect(result.error).to eq("not_pending")
    end
  end

  describe ".deny!" do
    it "still reports success when the applicant email can't be enqueued" do
      allow(ClinicianMailer).to receive(:denied_email).and_return(failing_delivery)

      result = described_class.deny!(application, admin: admin, notes: "No license on file.")

      expect(result.ok).to be true
      expect(application.reload).to be_denied
      expect(application.notes).to eq("No license on file.")
    end

    it "refuses an application that has already been reviewed" do
      application.update!(status: ClinicianApplication::APPROVED)

      result = described_class.deny!(application, admin: admin)

      expect(result.ok).to be false
      expect(result.error).to eq("not_pending")
    end
  end
end
