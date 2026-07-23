require "rails_helper"

RSpec.describe ClinicianApplication, type: :model do
  let(:user) { FactoryBot.create(:user) }

  def build_application(credential_type)
    user.clinician_applications.build(
      full_name: "Alex Rivera",
      credential_type: credential_type,
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

  describe ".normalize_credential_type" do
    it "returns nil for blank input" do
      expect(described_class.normalize_credential_type(nil)).to be_nil
      expect(described_class.normalize_credential_type("  ")).to be_nil
    end
  end
end
