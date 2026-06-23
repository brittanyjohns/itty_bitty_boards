require "rails_helper"

RSpec.describe BoardScreenshotImportJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:import) do
    imp = user.board_screenshot_imports.create!(status: "queued")
    imp.image.attach(
      io: File.open(Rails.root.join("spec/data/path_images/images/happy.png")),
      filename: "screenshot.png",
      content_type: "image/png",
    )
    imp
  end

  let(:vision_result) do
    {
      rows: 1, cols: 2, confidence_avg: 0.9,
      cells: [
        { row: 0, col: 0, label_raw: "Eat", label_norm: "eat", label: "eat", confidence: 0.9, bbox: [0, 0, 0, 0], bg_color: "white" },
        { row: 0, col: 1, label_raw: nil, label_norm: nil, label: "", confidence: 0.5, bbox: [0, 0, 0, 0], bg_color: "white" },
      ],
    }
  end

  # Stub the service via `.new` (not allow_any_instance_of, which leaks its
  # return/raise stub across examples under random ordering).
  let(:vision) { instance_double(BoardScreenshotVisionService) }

  # Stub preprocessing for every example so the job never shells out to
  # ImageMagick (not installed on CI) — otherwise the job would die at the
  # preprocess step before reaching the stubbed vision call. The temp path is a
  # real file so the job's cleanup (and the success-path assertion) is exercised.
  let(:preprocessed_temp) { Rails.root.join("tmp", "import_stub_#{SecureRandom.hex(4)}.jpg").to_s }
  before do
    allow(BoardScreenshotVisionService).to receive(:new).and_return(vision)
    File.write(preprocessed_temp, "stub")
    allow(ImagePreprocessor).to receive(:new).and_return(
      instance_double(ImagePreprocessor, process!: { path: preprocessed_temp, rotation: 0, debug: {} }),
    )
  end

  describe "success" do
    before { allow(vision).to receive(:parse_board).and_return(vision_result) }

    it "creates cells, marks the import needs_review, and deletes the preprocessed temp file" do
      described_class.new.perform(import.id)

      expect(import.reload.status).to eq("needs_review")
      expect(import.board_screenshot_cells.count).to eq(2)
      expect(import.guessed_cols).to eq(2)
      expect(File.exist?(preprocessed_temp)).to be(false)
    end
  end

  describe "failure refunds credits" do
    before { allow(vision).to receive(:parse_board).and_raise(StandardError, "vision boom") }

    it "marks the import failed and refunds the exact source split, idempotently" do
      spend = CreditService.spend!(user, feature_key: "screenshot_import")
      import.update!(metadata: { "credit_txn_id" => spend.id })
      balance_after_spend = user.reload.plan_credits_balance

      described_class.new.perform(import.id)

      expect(import.reload.status).to eq("failed")
      expect(import.error_message).to eq("vision boom")
      expect(user.reload.plan_credits_balance).to eq(balance_after_spend + CreditService.cost_for("screenshot_import"))
      expect(CreditTransaction.where(kind: "refund").count).to eq(1)

      # A Sidekiq retry must not double-refund.
      described_class.new.perform(import.id)
      expect(CreditTransaction.where(kind: "refund").count).to eq(1)
    end

    it "does not refund when no credit txn was recorded" do
      described_class.new.perform(import.id)
      expect(import.reload.status).to eq("failed")
      expect(CreditTransaction.where(kind: "refund").count).to eq(0)
    end
  end
end
