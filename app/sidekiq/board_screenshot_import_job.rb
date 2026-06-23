# app/sidekiq/board_screenshot_import_job.rb
require "mini_magick"

class BoardScreenshotImportJob
  include Sidekiq::Worker
  sidekiq_options queue: :ai_images, retry: 1, backtrace: true

  def perform(import_id, columns = nil)
    import = BoardScreenshotImport.find(import_id)
    import.update!(status: "processing")

    Rails.logger.debug "[BoardScreenshotImportJob] Starting import #{import.id}"

    processed_path = nil

    # 1) Get a local temp path for the uploaded screenshot (works with S3, etc.)
    import.image.open(tmpdir: Rails.root.join("tmp")) do |file|
      original_path = file.path

      # 2) Preprocess image (resize, deskew, contrast, etc.)
      preprocessed = ImagePreprocessor.new(original_path).process!
      processed_path = preprocessed[:path]

      # 3) Call OpenAI via service (like ImageEditService)
      vision_service = BoardScreenshotVisionService.new

      result = vision_service.parse_board(image_path: processed_path, cols: columns)

      # 4) Persist candidates + import metadata
      BoardScreenshotImport.transaction do
        import.update!(
          guessed_rows: result[:rows],
          guessed_cols: result[:cols],
          confidence_avg: result[:confidence_avg],
          metadata: (import.metadata || {}).merge(rotation: preprocessed[:rotation], debug: preprocessed[:debug]),
          status: "needs_review",
        )

        result[:cells].each do |c|
          import.board_screenshot_cells.create!(
            row: c[:row],
            col: c[:col],
            label_raw: c[:label_raw] || c[:label].to_s || "",
            label_norm: c[:label_norm] || c[:label].to_s || "",
            confidence: c[:confidence] || 0.0,
            bbox: c[:bbox],
            bg_color: c[:bg_color] || "white",
          )
        end
      end
    end

    Rails.logger.debug "[BoardScreenshotImportJob] Finished import #{import.id} - status: needs_review"
  rescue => e
    Rails.logger.error "[BoardScreenshotImportJob] Error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    if import
      import.update!(status: "failed", error_message: e.message)
      # The user was charged at upload; the analysis never produced a board, so
      # make them whole. Idempotent across the one Sidekiq retry.
      refund_credits!(import)
    end
  ensure
    # ImagePreprocessor writes a standalone temp file that the image.open block
    # does NOT clean up. Always unlink it so imports don't leak disk.
    begin
      File.delete(processed_path) if processed_path && File.exist?(processed_path)
    rescue => e
      Rails.logger.warn "[BoardScreenshotImportJob] temp cleanup failed: #{e.class}: #{e.message}"
    end
  end

  private

  # Refund the screenshot_import credits spent at upload time when the import
  # fails. Refunds to the exact plan/topup split recorded on the spend txn, and
  # guards against double-refund so the Sidekiq retry can't refund twice.
  def refund_credits!(import)
    txn_id = import.metadata&.dig("credit_txn_id")
    return unless txn_id

    spend = CreditTransaction.find_by(id: txn_id, kind: "spend")
    return unless spend

    already_refunded = CreditTransaction.where(kind: "refund")
      .where("metadata ->> 'refund_for_txn' = ?", spend.id.to_s)
      .exists?
    return if already_refunded

    user = import.user
    from_plan = spend.metadata["from_plan"].to_i
    from_topup = spend.metadata["from_topup"].to_i
    meta = { import_id: import.id, refund_for_txn: spend.id }

    CreditService.refund!(user, amount: from_plan, feature_key: "screenshot_import", source: "plan", metadata: meta) if from_plan.positive?
    CreditService.refund!(user, amount: from_topup, feature_key: "screenshot_import", source: "topup", metadata: meta) if from_topup.positive?
  rescue => e
    Rails.logger.error "[BoardScreenshotImportJob] refund failed for import=#{import&.id}: #{e.class}: #{e.message}"
  end
end
