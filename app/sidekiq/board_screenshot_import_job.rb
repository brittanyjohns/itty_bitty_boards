# app/sidekiq/board_screenshot_import_job.rb
require "mini_magick"

class BoardScreenshotImportJob
  include Sidekiq::Worker
  sidekiq_options queue: :default

  def perform(import_id)
    import = BoardScreenshotImport.find(import_id)
    import.update!(status: "processing")

    Rails.logger.info "[BoardScreenshotImportJob] Starting import #{import.id}"

    # 1) Get a local temp path for the uploaded screenshot (works with S3, etc.)
    import.image.open(tmpdir: Rails.root.join("tmp")) do |file|
      original_path = file.path

      # 2) Preprocess image (resize, deskew, contrast, etc.)
      preprocessed = ImagePreprocessor.new(original_path).process!
      processed_path = preprocessed[:path]

      # 3) Call OpenAI via service (like ImageEditService)
      vision_service = BoardScreenshotVisionService.new
      result = vision_service.parse_board(image_path: processed_path)

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
            label_norm: LabelMapper.normalize(c[:label_norm] || c[:label].to_s || ""),
            confidence: c[:confidence] || 0.0,
            bbox: c[:bbox],
          )
        end
      end
    end

    Rails.logger.info "[BoardScreenshotImportJob] Finished import #{import.id} - status: needs_review"
  rescue => e
    Rails.logger.error "[BoardScreenshotImportJob] Error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    import.update!(status: "failed", error_message: e.message) if import
  end
end
