class API::Account::ChildBoardsController < API::Account::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json
  before_action :authenticate_child_token!, only: %i[show current predictive_board]

  # GET /boards/1 or /boards/1.json
  def show
    set_child_board
    @board_with_images = @board.api_view_with_images
    child_permissions = {
      can_edit: false,
      can_delete: false,
    }
    Rails.logger.debug "Child Permissions: #{child_permissions}"
    render json: @board_with_images.merge(child_permissions)
  end

  def current
    @boards = boards_for_child
    Rails.logger.debug "Communicator Boards for child: #{@boards.map(&:id)}"
    @boards_with_images = @boards.map do |comm_board|
      comm_board.api_view
    end
    render json: @boards_with_images
  end

  def predictive_board
    Rails.logger.info "Fetching predictive board for child account #{current_account.id}"
    @board = Board.with_artifacts.find_by(id: params[:id])
    @user = current_account.user
    if @board.nil?
      @board = Board.predictive_default(@user)
      Rails.logger.info "#{Board.predictive_default_id} -- No account dynamic default board found - setting default board : #{@board.id}"
    end
    # expires_in 8.hours, public: true # Cache control header
    if stale?(etag: @board, last_modified: @board.updated_at)
      RailsPerformance.measure("Predictive Image Board") do
        @board_with_images = @board.api_view_with_predictive_images(@user)
      end
      # Will implement child permissions later
      child_permissions = {
        can_edit: false,
        can_delete: false,
      }
      Rails.logger.debug "Child Permissions: #{child_permissions}"
      render json: @board_with_images.merge(child_permissions)
    end

    # render json: @board.api_view_with_predictive_images(@user)
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_child_board
    @child_board = ChildBoard.includes(board: { board_images: { image: [:docs, :audio_files_attachments, :audio_files_blobs] } }).find(params[:id])
    @board = @child_board.board
  end

  def boards_for_child
    current_account.child_boards.with_artifacts
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :child_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  # Only allow a list of trusted parameters through.
  def board_params
    params.require(:board).permit(:child_id,
                                  :name,
                                  :parent_id,
                                  :parent_type,
                                  :description,
                                  :predefined,
                                  :number_of_columns,
                                  :next_words,
                                  :images,
                                  :layout,
                                  :image_ids,
                                  :image_id,
                                  :query,
                                  :page,
                                  :display_image_url)
  end
end
