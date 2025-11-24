# app/controllers/api/board_screenshot_imports_controller.rb
class API::BoardScreenshotImportsController < API::ApplicationController
  before_action :authenticate_token!

  def index
    @imports = current_user.board_screenshot_imports.order(created_at: :desc).all
    render json: @imports.map(&:index_view)
  end

  def show
    @import = current_user.board_screenshot_imports.find(params[:id])
    Rails.logger.info "Showing BoardScreenshotImport ID=#{@import.inspect} for User ID=#{current_user.id}"

    render json: @import.show_view
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
    board_screenshot = params[:board_screenshot] || board_screenshot_import_update_params
    cells_data = board_screenshot[:cells]
    ActiveRecord::Base.transaction do
      import.update!(board_screenshot_import_update_params.except(:cells))
      (cells_data || []).each do |c|
        cand = import.board_screenshot_cells.find(c[:id])
        label_norm = c[:label_norm].to_s.strip
        cand.update!(label_norm: label_norm)
      end
      import.update!(status: "needs_review")
    end
    render json: { ok: true }
  end

  def commit
    import = current_user.board_screenshot_imports.find(params[:id])
    board_image_id = params[:board_image_id]
    @board = Board.transaction { BoardFromScreenshot.commit!(import) }
    board_image = BoardImage.find_by(id: board_image_id)
    if board_image
      board_image.update!(predictive_board_id: @board.id)
    end
    render json: { ok: true, board_id: @board.id, slug: @board.slug }
  end

  private

  def board_screenshot_import_update_params
    params.permit(:rows, :cols, :guessed_rows, :guessed_cols, :name, cells: [:id, :label_norm])
  end
end
