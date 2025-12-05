class API::ChildBoardsController < API::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json
  skip_before_action :authenticate_token!, only: %i[show current]
  before_action :authenticate_child_token!, only: %i[show current]

  # GET /boards/1 or /boards/1.json
  def show
    set_child_board
    @board_with_images = @child_board.api_view_with_images(current_account.user)
    child_permissions = {
      can_edit: false,
      can_delete: false,
    }
    child_board_info = {
      child_board_id: @child_board.id,
    }
    render json: @board_with_images.merge(child_permissions).merge(child_board_info)
  end

  def current
    @boards = boards_for_child
    @boards_with_images = @boards.map do |child_board|
      child_board.api_view_with_images
    end
    render json: @boards_with_images
  end

  def toggle_favorite
    @child_board = ChildBoard.find(params[:id])

    result = @child_board.toggle_favorite
    # render json: @child_board.api_view
    unless result
      render json: { error: "You can only favorite 80 boards" }, status: :unprocessable_entity
      return
    end
    @child_board.reload
    @board_with_images = @child_board.api_view_with_images
    child_permissions = {
      can_edit: false,
      can_delete: false,
    }
    child_board_info = {
      child_board_id: @child_board.id,
    }

    render json: @board_with_images.merge(child_permissions).merge(child_board_info)
  end

  def update
    @child_board = ChildBoard.find(params[:id])
    if @child_board.update(board_params)
      render json: @child_board.api_view
    else
      render json: @child_board.errors, status: :unprocessable_entity
    end
  end

  def destroy
    Rails.logger.info "Deleting child board with ID: #{params[:id]}"

    @child_board = ChildBoard.find(params[:id])
    @board = @child_board.board
    unless @board.user_id == current_user.id
      Rails.logger.warn "Unauthorized attempt to delete child board ID: #{params[:id]} by user ID: #{current_user.id}"
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    if @board.is_template
      Rails.logger.info "Not deleting template board ID: #{@board.id}"
      @child_board.destroy
    else
      Rails.logger.info "Deleting associated board ID: #{@board.id}"
      @child_board.destroy
      @board.destroy
    end

    render json: { message: "child_board deleted" }
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_child_board
    @child_board = ChildBoard.includes(child_board: { board_images: { image: [:docs, :audio_files_attachments, :audio_files_blobs] } }).find(params[:id])
    @child_board = @child_board.child_board
  end

  def boards_for_child
    current_account.child_boards.with_artifacts
  end

  # Only allow a list of trusted parameters through.
  def board_params
    params.require(:child_board).permit(:favorite)
  end
end
