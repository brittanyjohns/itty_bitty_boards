class API::BoardExportsController < API::ApplicationController
  before_action :set_board_export

  def show
    render json: @board_export.api_view
  end

  def download
    return unless ready_to_download?

    # Redirect to the storage URL instead of buffering the whole (up to
    # 200MB) .obz through this Puma worker via send_data.
    redirect_to storage_url, allow_other_host: true
  end

  # Hands the caller the storage URL as JSON so the browser can *navigate* to
  # it rather than fetch() it. #download can't serve the web app directly: the
  # frontend's fetch carries an Authorization header, which makes it a
  # preflighted CORS request, and a preflighted request that redirects
  # cross-origin forces a second preflight — against S3, which has no CORS
  # rule for our origins and answers 403. Navigation isn't a CORS request at
  # all, and the presigned URL already carries an attachment disposition, so
  # the file downloads with the right name.
  #
  # #download stays as-is for non-browser callers (curl, native).
  def download_url
    return unless ready_to_download?

    render json: { url: storage_url }
  end

  private

  # Renders the not-ready 404 and returns false, so actions can `return unless`.
  def ready_to_download?
    return true if @board_export.completed? && @board_export.file.attached?

    render json: { error: "Export not ready" }, status: :not_found
    false
  end

  def storage_url
    @board_export.file.url(disposition: "attachment", filename: @board_export.file.filename.to_s)
  end

  # Scoped to the current user, so another user's export is a plain 404 rather
  # than a 403 that confirms it exists.
  def set_board_export
    @board_export = BoardExport.find_by(id: params[:id], user_id: current_user&.id)
    return if @board_export

    render json: { error: "Export not found" }, status: :not_found
  end
end
