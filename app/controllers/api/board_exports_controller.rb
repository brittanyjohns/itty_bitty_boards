class API::BoardExportsController < API::ApplicationController
  before_action :set_board_export

  def show
    render json: @board_export.api_view
  end

  def download
    unless @board_export.completed? && @board_export.file.attached?
      render json: { error: "Export not ready" }, status: :not_found
      return
    end

    send_data @board_export.file.download,
              filename: @board_export.file.filename.to_s,
              type: "application/zip",
              disposition: "attachment"
  end

  private

  # Scoped to the current user, so another user's export is a plain 404 rather
  # than a 403 that confirms it exists.
  def set_board_export
    @board_export = BoardExport.find_by(id: params[:id], user_id: current_user&.id)
    return if @board_export

    render json: { error: "Export not found" }, status: :not_found
  end
end
