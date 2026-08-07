module Admin
  class BoardPrintablesController < Admin::ApplicationController
    PUBLIC_BOARD_LIMIT = 100

    def index
      @printables = BoardPrintable.includes(:board).recent.limit(50)
      @board_search = params[:board_search]
      @boards = if @board_search.present?
        Board.where("name ILIKE ? OR CAST(id AS TEXT) = ?", "%#{@board_search}%", @board_search).limit(25)
      else
        []
      end

      public_boards = Board.public_boards
      @public_boards_count = public_boards.count
      @public_boards = public_boards.alphabetical.limit(PUBLIC_BOARD_LIMIT)

      @subboard_counts = direct_subboard_counts(@public_boards + @boards)
    end

    def show
      @printable = BoardPrintable.find(params[:id])
    end

    def create
      board = Board.find_by(id: params[:board_id])
      unless board
        redirect_to admin_dashboard_board_printables_path, alert: "Board not found."
        return
      end

      include_subboards = ActiveModel::Type::Boolean.new.cast(params[:include_subboards]) || false
      max_boards = (params[:max_boards].presence&.to_i || BoardPrintable::DEFAULT_MAX_BOARDS)
        .clamp(1, BoardPrintable::MAX_BOARDS_CEILING)

      board_ids = Boards::Printables::CollectPages.walk_board_tree(
        board: board,
        include_subboards: include_subboards,
        max_boards: max_boards,
      ).map(&:id)

      printable = BoardPrintable.create!(
        board: board,
        created_by: current_user,
        status: "pending",
        include_subboards: include_subboards,
        max_boards: max_boards,
        topic: params[:topic].presence,
        board_ids: board_ids,
      )

      GenerateBoardPrintableJob.perform_async(printable.id)

      redirect_to admin_dashboard_board_printable_path(printable), notice: "Generating printable for \"#{board.name}\"…"
    rescue Boards::Printables::CollectPages::TreeTooLargeError => e
      redirect_to admin_dashboard_board_printables_path, alert: e.message
    end

    private

    # Directly linked subboards per board, in one grouped query — the full tree
    # would need a walk per row, and the list can be 100 boards long. Self-links
    # are excluded because the tree walk skips them too.
    def direct_subboard_counts(boards)
      ids = boards.map(&:id).uniq
      return {} if ids.empty?

      # reorder(nil) drops BoardImage's default position ordering — Postgres
      # rejects an ORDER BY column that isn't in the GROUP BY.
      BoardImage
        .reorder(nil)
        .where(board_id: ids)
        .where.not(predictive_board_id: nil)
        .where("predictive_board_id != board_id")
        .group(:board_id)
        .distinct
        .count(:predictive_board_id)
    end
  end
end
