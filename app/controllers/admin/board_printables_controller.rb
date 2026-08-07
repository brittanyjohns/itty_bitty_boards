module Admin
  class BoardPrintablesController < Admin::ApplicationController
    PUBLIC_BOARD_LIMIT = 100
    SORTABLE_BOARD_COLUMNS = %w[name subboards created_at updated_at].freeze

    # Directly linked subboards, as a scalar subquery, so "sort by subboards"
    # happens in the database. Sorting the fetched page in Ruby would only
    # order the first PUBLIC_BOARD_LIMIT rows the *name* sort happened to
    # return, which is a different (and wrong) answer.
    SUBBOARD_COUNT_SQL = <<~SQL.squish.freeze
      (SELECT COUNT(DISTINCT bi.predictive_board_id)
         FROM board_images bi
        WHERE bi.board_id = boards.id
          AND bi.predictive_board_id IS NOT NULL
          AND bi.predictive_board_id <> bi.board_id)
    SQL

    def index
      @printables = BoardPrintable.includes(:board).recent.limit(50)
      @board_sort = params[:sort].presence_in(SORTABLE_BOARD_COLUMNS) || "name"
      @board_dir = params[:dir].presence_in(%w[asc desc]) || "asc"

      @board_search = params[:board_search]
      @boards = if @board_search.present?
        sorted_boards(Board.where("name ILIKE ? OR CAST(id AS TEXT) = ?", "%#{@board_search}%", @board_search)).limit(25)
      else
        []
      end

      public_boards = Board.public_boards
      @public_boards_count = public_boards.count
      @public_boards = sorted_boards(public_boards).limit(PUBLIC_BOARD_LIMIT)

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

    # @board_sort / @board_dir are whitelisted above, so they are safe to
    # interpolate. Every sort falls back to name so the order is total —
    # boards created in the same seed run otherwise shuffle between requests.
    def sorted_boards(scope)
      name_order = "LOWER(boards.name) ASC"

      case @board_sort
      when "name"
        scope.reorder(Arel.sql("LOWER(boards.name) #{@board_dir.upcase}"))
      when "subboards"
        scope.reorder(Arel.sql("#{SUBBOARD_COUNT_SQL} #{@board_dir.upcase}, #{name_order}"))
      else
        scope.reorder(Arel.sql("boards.#{@board_sort} #{@board_dir.upcase}, #{name_order}"))
      end
    end

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
