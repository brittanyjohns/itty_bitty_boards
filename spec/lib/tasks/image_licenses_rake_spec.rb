require "rails_helper"
require "rake"

RSpec.describe "images:license_audit", type: :task do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["images:license_audit"] }

  before do
    admin
    task.reenable
  end

  def doc_with(license:, source_type:)
    image = Image.create!(label: "audit-#{SecureRandom.hex(4)}", user_id: admin.id)
    image.docs.create!(user_id: admin.id, license: license, source_type: source_type, raw: image.label)
  end

  def invoke_task
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output
    task.invoke
    output.string
  ensure
    $stdout = original_stdout
  end

  it "reports counts by license type" do
    doc_with(license: { "type" => "CC BY-NC-SA" }, source_type: "ObfImport")

    output = invoke_task

    # Images::CommercialLicense normalizes #type to lowercase, so the audit's
    # by-license-type breakdown prints the normalized form, not the raw
    # jsonb casing.
    expect(output).to match(/CC BY-NC-SA/i)
  end

  it "reports the commercial-safe total" do
    doc_with(license: nil, source_type: "OpenAI")

    output = invoke_task

    # Anchor on the Totals line's count, not just the bare word — "commercial-safe"
    # also appears in the trailing explanatory note, which would match even if
    # the Totals line itself were deleted.
    expect(output).to match(/commercial-safe\s+1\b/)
  end

  it "reports counts by source_type" do
    doc_with(license: nil, source_type: "OpenAI")

    output = invoke_task

    expect(output).to match(/OpenAI/)
  end

  it "does not modify any records" do
    doc_with(license: { "type" => "CC BY" }, source_type: "ObfImport")
    before_updated = Doc.maximum(:updated_at)

    invoke_task

    expect(Doc.maximum(:updated_at)).to eq(before_updated)
  end
end
