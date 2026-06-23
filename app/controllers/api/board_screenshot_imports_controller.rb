# app/controllers/api/board_screenshot_imports_controller.rb
class API::BoardScreenshotImportsController < API::ApplicationController
  before_action :authenticate_token!

  def index
    @imports = current_user.board_screenshot_imports.order(created_at: :desc).all
    render json: @imports.map(&:index_view)
  end

  def show
    @import = current_user.board_screenshot_imports.find(params[:id])

    render json: @import.show_view(current_user)
  end

  def create
    name = params[:name]
    columns = sanitized_columns(params[:columns])
    cropped_image = params[:cropped_image]
    image = params[:image]

    import = current_user.board_screenshot_imports.new(
      name: name,
      status: "queued",
    )
    if cropped_image.present?
      import.image.attach(io: StringIO.new(Base64.decode64(cropped_image.split(",").last)),
                          filename: "screenshot_#{Time.now.to_i}.png",
                          content_type: "image/png")
    elsif image.present?
      import.image.attach(image)
    else
      render json: { error: "No image provided" }, status: :unprocessable_content
      return
    end
    import.save!
    return unless check_credits!(feature_key: "screenshot_import", feature_name: "AI Board Screenshot Imports")

    # Record the spend transaction so the job can refund the exact source split
    # if the AI analysis fails (the user is charged at upload, before the job runs).
    if @credit_spend_transaction
      import.update!(metadata: (import.metadata || {}).merge("credit_txn_id" => @credit_spend_transaction.id))
    end

    BoardScreenshotImportJob.perform_async(import.id, columns)
    render json: { id: import.id, status: import.status }
  end

  # Accept user-edited labels + (optional) rows/cols
  def update
    import = current_user.board_screenshot_imports.find(params[:id])
    board_screenshot = params[:board_screenshot].presence || board_screenshot_import_update_params
    cells_data = board_screenshot[:cells]
    cols = board_screenshot[:cols]
    ActiveRecord::Base.transaction do
      import.guessed_cols = cols if cols.present?
      (cells_data || []).each do |c|
        cand = import.board_screenshot_cells.find(c[:id])
        label_norm = c[:label_norm].to_s.strip
        bg_color = c[:bg_color].to_s.strip
        row = c[:row].to_s.strip
        col = c[:col].to_s.strip
        cand.label_norm = label_norm if label_norm.present?
        cand.bg_color = bg_color if bg_color.present?
        cand.row = row.to_i if row.present?
        cand.col = col.to_i if col.present?
        cand.save!
      end
      import.update!(status: "needs_review")
    end
    render json: { ok: true }
  end

  COMMITTABLE_STATUSES = %w[needs_review committed completed].freeze

  def commit
    import = current_user.board_screenshot_imports.find(params[:id])
    unless COMMITTABLE_STATUSES.include?(import.status)
      render json: { error: "import_not_ready", message: "This screenshot import isn't ready to build a board yet." },
             status: :unprocessable_content
      return
    end

    board_image_id = params[:board_image_id]
    @board = BoardFromScreenshot.commit!(import)
    board_image = BoardImage.find_by(id: board_image_id) if board_image_id.present?
    if board_image
      if board_image.update(predictive_board_id: @board.id)
        og_board = board_image.board
        snap_to_screen = og_board.settings["snap_to_screen"] if og_board.present?
        if snap_to_screen
          @board.settings["snap_to_screen"] = snap_to_screen
          @board.save!
        end
      else
        Rails.logger.error "Failed to link BoardImage ID=#{board_image.id} to predictive Board ID=#{@board.id}: #{board_image.errors.full_messages.join(", ")}"
      end
    end
    render json: { ok: true, board_id: @board.id, slug: @board.slug }
  end

  private

  # Coerce the client-supplied column count to a positive Integer, or nil
  # (auto-detect). Avoids charging credits then failing the job on a bad value.
  def sanitized_columns(value)
    return nil if value.blank?
    n = value.to_i
    n.positive? ? n : nil
  end

  def board_screenshot_import_update_params
    params.permit(:guessed_rows, :guessed_cols, :name, :cols, cells: [:id, :label_norm, :bg_color, :row, :col])
  end
end
