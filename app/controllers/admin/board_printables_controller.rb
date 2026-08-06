module Admin
  class BoardPrintablesController < Admin::ApplicationController
    def index
      @printables = BoardPrintable.includes(:board).recent.limit(50)
      @board_search = params[:board_search]
      @boards = if @board_search.present?
        Board.where("name ILIKE ? OR CAST(id AS TEXT) = ?", "%#{@board_search}%", @board_search).limit(25)
      else
        []
      end
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
  end
end
