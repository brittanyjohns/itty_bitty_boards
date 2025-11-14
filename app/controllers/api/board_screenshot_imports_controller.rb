# app/controllers/api/board_screenshot_imports_controller.rb
class API::BoardScreenshotImportsController < API::ApplicationController
  before_action :authenticate_token!

  def index
    @imports = current_user.board_screenshot_imports.order(created_at: :desc).all
    render json: @imports.map(&:index_view)
  end

  def show
    @import = current_user.board_screenshot_imports.find(params[:id])
    cells = @import.board_screenshot_cells.order(:row, :col).select(:id, :row, :col, :label_raw, :label_norm, :confidence, :bbox, :bg_color)
    screenshot_url = @import.display_url
    render json: {
      id: @import.id,
      name: @import.name,
      created_at: @import.created_at,
      screenshot_url: screenshot_url,
      status: @import.status,
      guessed_rows: @import.guessed_rows,
      guessed_cols: @import.guessed_cols,
      confidence_avg: @import.confidence_avg,
      cells: cells,
    }
  end

  def create
    name = params[:name]
    import = current_user.board_screenshot_imports.create!(
      name: name,
      image: params.require(:image),
      status: "queued",
    )
    Rails.logger.info "Created BoardScreenshotImport ID=#{import.id} for User ID=#{current_user.id}"
    BoardScreenshotImportJob.perform_async(import.id)
    render json: { id: import.id, status: import.status }
  end

  # Accept user-edited labels + (optional) rows/cols
  def update
    import = current_user.board_screenshot_imports.find(params[:id])
    ActiveRecord::Base.transaction do
      import.update!(board_screenshot_import_update_params.except(:cells))
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

  private

  def board_screenshot_import_update_params
    params.permit(:rows, :cols, :guessed_rows, :guessed_cols, :name, cells: [:id, :label_norm])
  end
end
