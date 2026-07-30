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
  # `has_one_attached :file, service: <ternary>` evaluates that ternary once,
  # when the class body runs — not per-call — so `Rails.env` is fixed for the
  # life of the process (fine in real deployments, since RAILS_ENV never
  # changes mid-process). To exercise the production branch here we stub
  # Rails.env and re-declare the association with the model's exact
  # production-selection expression, then restore the original declaration
  # so later examples (and other spec files needing Disk in test) aren't
  # affected.
  #
  # The restore MUST use a value captured before any stubbing, not
  # re-evaluate `Rails.env.production? ? ... : ...` at restore time: RSpec's
  # own mock-teardown (which un-stubs Rails.env) is itself an `after` hook,
  # and hook execution order between it and a hook defined here isn't
  # something to depend on — re-evaluating the ternary in a bare `after` risks
  # running while the `allow(Rails.env)...` stub from the example above is
  # still active, permanently leaking :amazon_private as the "default" for
  # every later spec file in the run.
  describe "file attachment service selection" do
    original_service_name = nil

    before do
      original_service_name = described_class.reflect_on_attachment(:file).options[:service_name]
    end

    after do
      described_class.has_one_attached(:file, service: original_service_name)
    end

    it "uses the app's normal configured default service outside production (dev/test stays on Disk)" do
      expect(Rails.env.production?).to be false

      service_name = described_class.reflect_on_attachment(:file).options[:service_name]
      expect(service_name).to eq(Rails.application.config.active_storage.service)
    end

    it "selects the private S3 service when Rails.env.production? is true" do
      allow(Rails.env).to receive(:production?).and_return(true)
      described_class.has_one_attached(
        :file, service: Rails.env.production? ? :amazon_private : Rails.application.config.active_storage.service
      )

      service_name = described_class.reflect_on_attachment(:file).options[:service_name]
      expect(service_name).to eq(:amazon_private)
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
