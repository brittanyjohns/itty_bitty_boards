# app/jobs/board_image_import_job.rb
class BoardImageImportJob < ApplicationJob
  include Sidekiq::Job

  def perform(import_id)
    import = BoardImageImport.find(import_id)
    import.update!(status: "processing")

    # 1) Download image
    img_path = import.image.blob.service.send(:path_for, import.image.key) rescue import.image.path

    # 2) Preprocess (deskew + contrast). Omit details; call out to a service object.
    pre = ImagePreprocessor.new(img_path).process! # returns { path:, debug:, rotation:, ... }

    # 3) Ask vision model for layout & labels
    result = VisionParser.new(pre[:path]).parse!
    # result => { rows:, cols:, cells:[{row:, col:, label:, confidence:, bbox:[x,y,w,h]}], confidence_avg: }

    BoardImageImport.transaction do
      import.update!(
        guessed_rows: result[:rows],
        guessed_cols: result[:cols],
        confidence_avg: result[:confidence_avg],
        metadata: { rotation: pre[:rotation], debug: pre[:debug] },
        status: "needs_review",
      )
      result[:cells].each do |c|
        import.board_cell_candidates.create!(
          row: c[:row], col: c[:col],
          label_raw: c[:label] || "",
          label_norm: LabelMapper.normalize(c[:label]),
          confidence: c[:confidence] || 0.0,
          bbox: c[:bbox],
        )
      end
    end
  rescue => e
    import.update!(status: "failed", error_message: e.message)
    Rails.logger.error(e.full_message)
  end
end
