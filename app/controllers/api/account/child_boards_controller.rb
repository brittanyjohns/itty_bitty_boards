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
    @boards_with_images = @boards.map do |comm_board|
      comm_board.api_view
    end
    render json: @boards_with_images
  end

  def predictive_board
    @board = Board.with_artifacts.find_by(id: params[:id])
    @user = current_account.user

    if @board.nil?
      @board = Board.predictive_default(@user)
      Rails.logger.info "#{Board.predictive_default_id} -- No account dynamic default board found - setting default board : #{@board.id}"
    end

    # normalize voice
    voice = params[:voice].presence
    voice = "openai:alloy" if voice == "alloy"
    effective_voice = voice || @board.voice

    last_modified = board_predictive_last_modified(@board)

    etag = [
      @board.cache_key_with_version,
      @user&.id,
      current_account&.id,
      effective_voice,
      last_modified&.to_i,
    ]

    if stale?(etag: etag, last_modified: last_modified, template: false)
      @board_with_images = RailsPerformance.measure("Predictive Image Board") do
        @board.api_view_with_predictive_images(@user, false, effective_voice)
      end

      child_permissions = {
        can_edit: false,
        can_delete: false,
      }

      render json: @board_with_images.merge(child_permissions)
    end
  end

  private

  def board_predictive_last_modified(board)
    # uses MAX(updated_at) across the stuff that affects this JSON
    BoardImage
      .where(board_id: board.id)
      .joins(:image)
      .left_joins(image: :docs)
      .maximum("GREATEST(board_images.updated_at, images.updated_at, COALESCE(docs.updated_at, '1970-01-01'))") ||
      board.updated_at
  end

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
