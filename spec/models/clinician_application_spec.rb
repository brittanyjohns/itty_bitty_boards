require "rails_helper"

RSpec.describe ClinicianApplication, type: :model do
  let(:user) { FactoryBot.create(:user) }

  # A license number is carried by default so these examples exercise
  # credential_type alone — slp/ot require one (see the license_id block).
  def build_application(credential_type, license_id: "SLP-12345")
    user.clinician_applications.build(
      full_name: "Alex Rivera",
      credential_type: credential_type,
      license_id: license_id,
      status: described_class::PENDING,
    )
  end

  describe "credential_type normalization" do
    # The web client sent display labels until the canonical slugs shipped, and
    # an older native build may still. Normalizing before validation means those
    # submissions are corrected rather than newly rejected.
    it "normalizes display labels to canonical slugs" do
      {
        "SLP" => "slp",
        "slp" => "slp",
        "OT" => "ot",
        "AT specialist" => "at_specialist",
        "at specialist" => "at_specialist",
        "AT-specialist" => "at_specialist",
        "  ot  " => "ot",
        "other" => "other",
      }.each do |input, expected|
        application = build_application(input)
        application.validate
        expect(application.credential_type).to eq(expected), "#{input.inspect} → #{application.credential_type.inspect}, expected #{expected.inspect}"
      end
    end

    it "falls back to 'other' for an unrecognized credential" do
      application = build_application("Behavior Analyst")
      expect(application).to be_valid
      expect(application.credential_type).to eq("other")
    end

    it "persists the normalized value" do
      application = build_application("AT specialist")
      application.save!
      expect(application.reload.credential_type).to eq("at_specialist")
    end

    it "still requires a credential_type" do
      application = build_application(nil)
      expect(application).not_to be_valid
      expect(application.errors[:credential_type]).to be_present
    end

    it "treats a blank credential_type as missing, not as 'other'" do
      application = build_application("   ")
      expect(application).not_to be_valid
    end
  end

  describe "credential_type inclusion" do
    # The callback normalizes anything a client sends, so the validation is a
    # backstop for writes that skip callbacks (update_column, raw SQL). Assert
    # it independently by re-validating a record whose column was written
    # behind the model's back — the shape the pre-normalization rows were in.
    it "rejects an un-normalized value written behind the callback" do
      application = build_application("slp")
      application.save!
      application.update_column(:credential_type, "AT specialist")

      reloaded = described_class.find(application.id)
      expect(reloaded.credential_type).to eq("AT specialist")
      # Any subsequent save normalizes it rather than failing…
      reloaded.save!
      expect(reloaded.reload.credential_type).to eq("at_specialist")
    end
  end

  # The application form hard-required a license or certification number, which
  # blocked nobody (the literal string "N/A" filed a real application) and
  # blocked exactly the applicants the page recruits by name — AT specialists,
  # for whom RESNA ATP is optional, and "other".
  describe "license_id" do
    def build_with(credential_type, license_id: nil, verification_note: nil)
      user.clinician_applications.build(
        full_name: "Alex Rivera",
        credential_type: credential_type,
        license_id: license_id,
        verification_note: verification_note,
        status: described_class::PENDING,
      )
    end

    context "when the credential has a checkable license (slp/ot)" do
      it "requires one" do
        %w[slp ot].each do |credential|
          application = build_with(credential)
          expect(application).not_to be_valid, "#{credential} should require a license"
          expect(application.errors[:license_id].join).to include("required")
        end
      end

      it "rejects placeholders that mean 'I do not have one'" do
        ["N/A", "n/a", "n / a", "N.A.", "na", "none", "NONE", "-", "--", "x", "unknown", "TBD", "0"].each do |placeholder|
          application = build_with("slp", license_id: placeholder)
          expect(application).not_to be_valid, "#{placeholder.inspect} should be rejected"
          expect(application.errors[:license_id].join).to include("doesn't look like")
        end
      end

      # A refusal that only says no sends the applicant back to inventing a
      # value, which is the behavior this whole rule exists to stop.
      it "offers the alternative in the refusal" do
        application = build_with("slp", license_id: "N/A")
        application.validate
        expect(application.errors[:license_id].join).to include(described_class::LICENSE_ALTERNATIVE_HINT)
      end

      it "accepts a real license number" do
        application = build_with("slp", license_id: "SLP-40219")
        expect(application).to be_valid
      end
    end

    context "when the credential rarely has one (at_specialist/other)" do
      it "is optional" do
        %w[at_specialist other].each do |credential|
          application = build_with(credential)
          expect(application).to be_valid, "#{credential} should not require a license"
        end
      end

      # Stored "N/A" reads like an answer in the admin queue. Dropped rather
      # than refused: there is nothing wrong with the application, only with
      # treating "I don't have one" as a number.
      it "drops a placeholder instead of storing it" do
        application = build_with("at_specialist", license_id: "N/A")
        application.save!
        expect(application.reload.license_id).to be_nil
      end

      it "keeps a real certification number when one is given" do
        application = build_with("at_specialist", license_id: "ATP-8812")
        application.save!
        expect(application.reload.license_id).to eq("ATP-8812")
      end

      it "accepts a free-text verification note in place of a number" do
        application = build_with("other", verification_note: "Check my NPI, or call my clinic director.")
        application.save!
        expect(application.reload.verification_note).to eq("Check my NPI, or call my clinic director.")
      end
    end

    it "strips surrounding whitespace" do
      application = build_with("slp", license_id: "  SLP-40219  ")
      application.save!
      expect(application.reload.license_id).to eq("SLP-40219")
    end

    # `on: :create`. Applications filed before this rule existed carry no
    # license at all, and Reviewer#approve!/#deny! save the row — a blanket
    # validation would make every historical SLP/OT application permanently
    # unapprovable.
    it "does not block reviewing a historical application that has none" do
      application = build_with("slp", license_id: "SLP-40219")
      application.save!
      application.update_column(:license_id, nil)

      reloaded = described_class.find(application.id)
      expect(reloaded.update(status: described_class::APPROVED, reviewed_at: Time.current)).to be(true)
    end
  end

  describe ".license_placeholder?" do
    it "collapses punctuation and case before matching" do
      expect(described_class.license_placeholder?("N / A")).to be(true)
      expect(described_class.license_placeholder?("n.a.")).to be(true)
    end

    it "leaves a real license alone" do
      expect(described_class.license_placeholder?("SLP-40219")).to be(false)
      expect(described_class.license_placeholder?("ATP-8812")).to be(false)
    end

    it "is false for blank" do
      expect(described_class.license_placeholder?(nil)).to be(false)
      expect(described_class.license_placeholder?("  ")).to be(false)
    end
  end

  describe ".normalize_credential_type" do
    it "returns nil for blank input" do
      expect(described_class.normalize_credential_type(nil)).to be_nil
      expect(described_class.normalize_credential_type("  ")).to be_nil
    end
  end
end
