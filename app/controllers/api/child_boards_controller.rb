class API::ChildBoardsController < API::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json
  skip_before_action :authenticate_token!, only: %i[show current]
  before_action :authenticate_child_token!, only: %i[show current]
  before_action :load_child_board, only: %i[toggle_favorite update destroy]
  before_action :authorize_curate!, only: %i[toggle_favorite update]
  before_action :authorize_detach!, only: %i[destroy]

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
    result = @child_board.toggle_favorite
    unless result
      render json: { error: "You can only favorite 80 boards" }, status: :unprocessable_content
      return
    end
    @child_account = ChildAccount.includes(child_boards: :board).find(@child_board.child_account_id)
    render json: @child_account.api_view(current_user), status: :ok
  end

  def update
    if @child_board.update(board_params)
      render json: @child_board.api_view
    else
      render json: @child_board.errors, status: :unprocessable_content
    end
  end

  def destroy
    Rails.logger.info "Deleting child board with ID: #{params[:id]}"
    @board = @child_board.board
    @child_board.destroy

    # Removal is non-destructive by default: detach the board from this
    # dashboard but keep the board record. We only delete the underlying
    # board when it's a throwaway per-communicator template that nothing
    # else references — never one that's a team board or still on another
    # communicator. This lets a hand-off owner clear inherited boards
    # without destroying content the team (or the original SLP) relies on,
    # while preserving the old cleanup for a self-created template clone.
    if @board && @board.is_template && orphan_template?(@board)
      Rails.logger.info "Deleting orphaned template board ID: #{@board.id}"
      # Deep-cloned sub-boards (Boards::AssignmentCloner) are marked with the
      # root clone's id; collect them before the root goes so they can be
      # swept once the root's folder tiles no longer reference them.
      sweepable = assignment_sub_templates(@board)
      @board.destroy
      sweep_orphaned_sub_templates!(sweepable)
    else
      Rails.logger.info "Detached child_board #{params[:id]}; preserved board ID: #{@board&.id}"
    end

    render json: { message: "child_board deleted" }
  end

  private

  # A per-communicator template clone is safe to hard-delete only when
  # nothing else references it: it's not shared as a team board, it's not on
  # any other communicator's dashboard (the just-removed ChildBoard is
  # already destroyed by the time we check), and the remover owns it. In any
  # other case we detach only, so removing a board from one dashboard can
  # never destroy content another surface still depends on.
  def orphan_template?(board)
    return false if board.team_boards.exists?
    return false if board.child_boards.exists?
    # A folder tile on another board still opens this one — deleting it would
    # nullify that tile into a dead button. Detach only.
    return false if BoardImage.where(predictive_board_id: board.id).where.not(board_id: board.id).exists?
    board.user_id == current_user&.id
  end

  # Sub-board clones minted by Boards::AssignmentCloner for this root clone.
  def assignment_sub_templates(root_board)
    Board.where(user_id: current_user&.id, is_template: true)
         .where("settings->>'assignment_root_id' = ?", root_board.id.to_s)
         .to_a
  end

  # Destroy the set's sub-templates that are now orphans, applying the same
  # never-delete-something-referenced guards. Nested folders reference each
  # other, so destroying a parent frees its children — iterate until a pass
  # deletes nothing. (A reference cycle between two sub-boards leaves both in
  # place; acceptable, they're invisible template rows.)
  def sweep_orphaned_sub_templates!(sweepable)
    until sweepable.empty?
      deletable = sweepable.select { |b| orphan_template?(b) }
      break if deletable.empty?

      deletable.each do |board|
        Rails.logger.info "Sweeping orphaned assignment sub-template board ID: #{board.id}"
        board.destroy
      end
      sweepable -= deletable
    end
  end

  def load_child_board
    @child_board = ChildBoard.find(params[:id])
  end

  # Curation tier: owner, admin, or any team member with
  # admin/member/supporter role on the communicator. Backs the favorite
  # toggle and any other curation-only field on the join row.
  def authorize_curate!
    return if @child_board.curatable_by?(current_user)

    Rails.logger.warn "Unauthorized curation attempt on child_board ID: #{@child_board.id} by user ID: #{current_user&.id}"
    render json: { error: "Unauthorized" }, status: :forbidden
  end

  # Detach (destroy) is owner-only. Letting a supervisor unshare a board
  # via this endpoint would bypass `TeamUser#before_destroy`'s snapshot
  # safety net — the family would lose access to a board they were
  # relying on. If an SLP wants to stop sharing, she removes herself
  # from the team, which triggers the snapshot copy.
  def authorize_detach!
    return if @child_board.child_account.editable_by?(current_user)

    Rails.logger.warn "Unauthorized detach attempt on child_board ID: #{@child_board.id} by user ID: #{current_user&.id}"
    render json: { error: "Unauthorized" }, status: :forbidden
  end

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
