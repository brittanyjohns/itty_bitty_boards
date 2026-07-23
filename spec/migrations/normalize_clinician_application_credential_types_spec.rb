require "rails_helper"
require Rails.root.join("db/migrate/20260723120000_normalize_clinician_application_credential_types.rb")

# The rows this migration exists for were written before the model normalized
# or validated credential_type, so they can only be created here by writing the
# column behind the callback.
RSpec.describe NormalizeClinicianApplicationCredentialTypes do
  let(:migration) { described_class.new }

  def application_with_raw_credential(raw)
    application = FactoryBot.create(:user).clinician_applications.create!(
      full_name: "Alex Rivera",
      credential_type: "slp",
      status: ClinicianApplication::PENDING,
    )
    application.update_column(:credential_type, raw)
    application
  end

  before { migration.verbose = false }

  it "backfills display labels to canonical slugs" do
    slp = application_with_raw_credential("SLP")
    at = application_with_raw_credential("AT specialist")

    migration.up

    expect(slp.reload.credential_type).to eq("slp")
    expect(at.reload.credential_type).to eq("at_specialist")
  end

  it "maps an unrecognized credential to 'other'" do
    odd = application_with_raw_credential("Behavior Analyst")

    migration.up

    expect(odd.reload.credential_type).to eq("other")
  end

  it "leaves already-canonical rows untouched" do
    canonical = application_with_raw_credential("at_specialist")

    expect { migration.up }.not_to(change { canonical.reload.updated_at })
    expect(canonical.reload.credential_type).to eq("at_specialist")
  end

  it "is idempotent" do
    application = application_with_raw_credential("SLP")

    migration.up
    migration.up

    expect(application.reload.credential_type).to eq("slp")
  end

  it "leaves every row valid against the new inclusion rule" do
    application_with_raw_credential("SLP")
    application_with_raw_credential("AT specialist")
    application_with_raw_credential("Behavior Analyst")

    migration.up

    expect(ClinicianApplication.all).to all(be_valid)
  end
end
