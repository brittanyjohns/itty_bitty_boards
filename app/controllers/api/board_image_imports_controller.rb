# app/controllers/api/board_image_imports_controller.rb
class API::BoardImageImportsController < ApplicationController
  before_action :authenticate_user!

  def create
    import = current_user.board_image_imports.create!(
      image: params.require(:image),
      status: "queued",
    )
    BoardImageImportJob.perform_later(import.id)
    render json: { id: import.id, status: import.status }
  end

  def show
    import = current_user.board_image_imports.find(params[:id])
    cells = import.board_cell_candidates.order(:row, :col).select(:id, :row, :col, :label_raw, :label_norm, :confidence, :bbox)
    render json: {
      id: import.id,
      status: import.status,
      guessed_rows: import.guessed_rows,
      guessed_cols: import.guessed_cols,
      confidence_avg: import.confidence_avg,
      cells: cells,
    }
  end

  # Accept user-edited labels + (optional) rows/cols
  def update
    import = current_user.board_image_imports.find(params[:id])
    ActiveRecord::Base.transaction do
      if params[:guessed_rows] && params[:guessed_cols]
        import.update!(guessed_rows: params[:guessed_rows], guessed_cols: params[:guessed_cols])
      end
      (params[:cells] || []).each do |c|
        cand = import.board_cell_candidates.find(c[:id])
        cand.update!(label_norm: c[:label_norm].to_s.strip)
      end
      import.update!(status: "needs_review")
    end
    render json: { ok: true }
  end

  def commit
    import = current_user.board_image_imports.find(params[:id])
    board = Board.transaction { BoardFromImage.commit!(import) }
    render json: { ok: true, board_id: board.id, slug: board.slug }
  end
end
