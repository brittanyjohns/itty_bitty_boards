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
    columns = params[:columns]
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
      render json: { error: "No image provided" }, status: :unprocessable_entity
      return
    end
    import.save!
    return unless check_daily_limit("ai_screenshot_imports")
    BoardScreenshotImportJob.perform_async(import.id, columns)
    render json: { id: import.id, status: import.status }
  end

  # Accept user-edited labels + (optional) rows/cols
  def update
    import = current_user.board_screenshot_imports.find(params[:id])
    board_screenshot = params[:board_screenshot] || board_screenshot_import_update_params
    cells_data = board_screenshot[:cells]
    cols = params[:board_screenshot][:cols]
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
      if import.update(status: "needs_review")
        render json: { ok: true }
      else
        render json: { error: "Failed to update import" }, status: :unprocessable_entity
      end
    end
  end

  def commit
    import = current_user.board_screenshot_imports.find(params[:id])
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
        Rails.logger.info "Linked BoardImage ID=#{board_image.id} to predictive Board ID=#{@board.id}"
      else
        Rails.logger.error "Failed to link BoardImage ID=#{board_image.id} to predictive Board ID=#{@board.id}: #{board_image.errors.full_messages.join(", ")}"
      end
    else
      Rails.logger.info "No BoardImage found with ID=#{board_image_id} to link to predictive board."
    end
    render json: { ok: true, board_id: @board.id, slug: @board.slug }
  end

  private

  def board_screenshot_import_update_params
    params.permit(:guessed_rows, :guessed_cols, :name, :cols, cells: [:id, :label_norm, :bg_color])
  end
end
