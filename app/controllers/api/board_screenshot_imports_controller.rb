# app/controllers/api/board_screenshot_imports_controller.rb
class API::BoardScreenshotImportsController < API::ApplicationController
  before_action :authenticate_token!

  def create
    import = current_user.board_screenshot_imports.create!(
      image: params.require(:image),
      status: "queued",
    )
    Rails.logger.info "Created BoardScreenshotImport ID=#{import.id} for User ID=#{current_user.id}"
    BoardScreenshotImportJob.perform_async(import.id)
    render json: { id: import.id, status: import.status }
  end

  def show
    import = current_user.board_screenshot_imports.find(params[:id])
    cells = import.board_screenshot_cells.order(:row, :col).select(:id, :row, :col, :label_raw, :label_norm, :confidence, :bbox)
    screenshot_url = import.display_url
    render json: {
      id: import.id,
      screenshot_url: screenshot_url,
      status: import.status,
      guessed_rows: import.guessed_rows,
      guessed_cols: import.guessed_cols,
      confidence_avg: import.confidence_avg,
      cells: cells,
    }
  end

  # Accept user-edited labels + (optional) rows/cols
  def update
    import = current_user.board_screenshot_imports.find(params[:id])
    ActiveRecord::Base.transaction do
      if params[:guessed_rows] && params[:guessed_cols]
        import.update!(guessed_rows: params[:guessed_rows], guessed_cols: params[:guessed_cols])
      end
      (params[:cells] || []).each do |c|
        cand = import.board_screenshot_cells.find(c[:id])
        cand.update!(label_norm: c[:label_norm].to_s.strip)
      end
      import.update!(status: "needs_review")
    end
    render json: { ok: true }
  end

  def commit
    import = current_user.board_screenshot_imports.find(params[:id])
    board = Board.transaction { BoardFromScreenshot.commit!(import) }
    render json: { ok: true, board_id: board.id, slug: board.slug }
  end
end
