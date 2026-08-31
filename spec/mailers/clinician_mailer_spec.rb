require "rails_helper"

# These templates are only ever reached through a mocked `deliver_later` double
# in the request specs, so this file is the one place they actually render.
RSpec.describe ClinicianMailer, type: :mailer do
  let(:applicant) { FactoryBot.create(:user, email: "sam.lee+slp@clinic.org", name: "Sam Lee") }

  def application(attrs = {})
    ClinicianApplication.create!(
      {
        user: applicant,
        status: ClinicianApplication::PENDING,
        full_name: "Samantha Lee, MS CCC-SLP",
        credential_type: "slp",
        license_id: "SLP-12345",
        workplace: "Riverside Clinic",
      }.merge(attrs),
    )
  end

  def body_of(mail)
    (mail.html_part || mail).body.decoded
  end

  describe "#application_received_email" do
    it "addresses the applicant and sets the review-by-hand expectation" do
      mail = described_class.application_received_email(application).deliver_now

      expect(mail.to).to eq(["sam.lee+slp@clinic.org"])
      expect(mail.subject).to eq("We got your SpeakAnyWay for Clinicians application")
      expect(body_of(mail)).to include("Hi Sam Lee,")
      expect(body_of(mail)).to include("review every clinician application by hand")
    end
  end

  describe "#approved_email" do
    it "renders the approval subject, body and CTA" do
      mail = described_class.approved_email(application).deliver_now

      expect(mail.to).to eq(["sam.lee+slp@clinic.org"])
      expect(mail.subject).to eq("Your SpeakAnyWay Clinician account is ready")
      expect(body_of(mail)).to include("You&#39;re approved 🎉")
      expect(body_of(mail)).to include("Sign in to SpeakAnyWay")
    end

    it "escapes the email in the sign-in link" do
      mail = described_class.approved_email(application).deliver_now

      expect(body_of(mail)).to include("/users/sign-in?email=sam.lee%2Bslp%40clinic.org")
    end
  end

  describe "#denied_email" do
    it "renders the denial subject and leaves the door open to re-apply" do
      mail = described_class.denied_email(application).deliver_now

      expect(mail.subject).to eq("About your SpeakAnyWay for Clinicians application")
      expect(body_of(mail)).to include("apply again")
    end

    it "includes the admin's note when one was left" do
      mail = described_class.denied_email(
        application(notes: "We couldn't match that license number."),
      ).deliver_now

      expect(body_of(mail)).to include("We couldn&#39;t match that license number.")
    end

    it "omits the note paragraph when the admin denied without one" do
      mail = described_class.denied_email(application(notes: nil)).deliver_now

      expect(body_of(mail)).not_to include("class=\"quote\"")
    end
  end

  describe "the greeting name" do
    let(:applicant) { FactoryBot.create(:user, email: "noname@clinic.org", name: nil) }

    it "falls back to the name on the application when the user record has none" do
      mail = described_class.approved_email(application).deliver_now

      expect(body_of(mail)).to include("Hi Samantha Lee, MS CCC-SLP,")
    end
  end

  describe "a non-English recipient" do
    # config/locales/mailer.es.yml has no clinician_mailer block, so these fall
    # back to :en rather than raising on a missing translation.
    before do
      applicant.settings ||= {}
      applicant.settings["voice"] = { "language" => "es-US" }
      applicant.save!
    end

    it "still renders, in English" do
      mail = described_class.approved_email(application).deliver_now

      expect(mail.subject).to eq("Your SpeakAnyWay Clinician account is ready")
      expect(body_of(mail)).to include("Sign in to SpeakAnyWay")
    end
  end
end
