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

  # Task 9's controller redirects to `file.url(...)`, which is only genuinely
  # presigned/expiring when the underlying service is NOT `public: true`
  # (config/storage.yml's `amazon` service is; the new `amazon_private`
  # service is not). This proves BoardExport routes to the private service in
  # production without needing real AWS credentials.
  #
  # `has_one_attached :file, service: file_service_name` evaluates the method
  # once, when the class body runs — not per-call — so `Rails.env` is fixed
  # for the life of the process (fine in real deployments, since RAILS_ENV
  # never changes mid-process). These specs assert on `file_service_name`
  # directly rather than re-invoking `has_one_attached` with a stubbed
  # Rails.env: re-declaring the association eagerly constructs a real S3
  # client (to resolve the named service), which attempts AWS
  # credential-resolution network calls that WebMock blocks in CI — the
  # method-extraction avoids that entirely, no mocking or restore-ordering
  # needed.
  describe "file attachment service selection" do
    it "uses the app's normal configured default service outside production (dev/test stays on Disk)" do
      expect(Rails.env.production?).to be false
      expect(described_class.file_service_name).to eq(Rails.application.config.active_storage.service)
    end

    it "selects the private S3 service when Rails.env.production? is true" do
      allow(Rails.env).to receive(:production?).and_return(true)
      expect(described_class.file_service_name).to eq(:amazon_private)
    end
  end

  # Fix 4 (final whole-branch review): both boards#export_package and
  # board_groups#export_package independently 409 on
  # `board_exports.where(status: %w[queued processing]).exists?` with no time
  # bound, so a BoardExport a dead job left stuck in "processing" permanently
  # locked the user out. `.in_flight` adds the staleness bound both
  # controllers now share.
  describe ".in_flight" do
    it "includes a queued or processing export within the staleness window" do
      queued = described_class.create!(user: user, exportable: board, status: "queued",
                                       created_at: 5.minutes.ago)
      processing = described_class.create!(user: user, exportable: board, status: "processing",
                                           created_at: 5.minutes.ago)

      expect(described_class.in_flight).to include(queued, processing)
    end

    it "excludes a queued or processing export older than the staleness window" do
      stale = described_class.create!(user: user, exportable: board, status: "processing",
                                       created_at: (BoardExport::IN_FLIGHT_STALENESS + 1.minute).ago)

      expect(described_class.in_flight).not_to include(stale)
    end

    it "excludes completed and failed exports regardless of age" do
      completed = described_class.create!(user: user, exportable: board, status: "completed")
      failed = described_class.create!(user: user, exportable: board, status: "failed")

      expect(described_class.in_flight).not_to include(completed, failed)
    end
  end
end
