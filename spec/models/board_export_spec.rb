require "rails_helper"

RSpec.describe BoardExport do
  let(:user)  { create(:user) }
  let(:board) { create(:board, user: user) }

  it "defaults to queued" do
    expect(described_class.create!(user: user, exportable: board).status).to eq("queued")
  end

  it "rejects an unknown status" do
    record = described_class.new(user: user, exportable: board, status: "nonsense")
    expect(record).not_to be_valid
  end

  it "reports no download url until the file is attached" do
    record = described_class.create!(user: user, exportable: board, status: "completed")
    expect(record.api_view[:download_url]).to be_nil
  end

  it "exposes status and error in the api view" do
    record = described_class.create!(user: user, exportable: board,
                                     status: "failed", error_message: "boom")
    view = record.api_view
    expect(view[:status]).to eq("failed")
    expect(view[:error_message]).to eq("boom")
  end
end
