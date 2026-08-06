class API::Admin::BoardPrintablesController < API::Admin::ApplicationController
  before_action :set_printable, only: [:show, :download_url]

  # POST /api/admin/boards/:board_id/printables
  def create
    board = Board.find_by(id: params[:board_id])
    return render json: { error: "Board not found" }, status: :not_found unless board

    # The tree is walked here, synchronously, BEFORE anything is created —
    # an over-cap tree has to answer 422, and a job that raises can't. It's a
    # cheap id-only walk; the job re-walks when it renders.
    board_ids = Boards::Printables::CollectPages.walk_board_tree(
      board: board,
      include_subboards: include_subboards?,
      max_boards: max_boards,
    ).map(&:id)

    printable = BoardPrintable.create!(
      board: board,
      created_by: current_admin,
      status: "pending",
      include_subboards: include_subboards?,
      max_boards: max_boards,
      topic: params[:topic].presence,
      board_ids: board_ids,
    )

    GenerateBoardPrintableJob.perform_async(printable.id)

    render json: printable.api_view, status: :accepted
  rescue Boards::Printables::CollectPages::TreeTooLargeError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  # GET /api/admin/board_printables/:id
  def show
    render json: @printable.api_view
  end

  # GET /api/admin/board_printables/:id/download_url
  #
  # Hands back the storage URLs as JSON so the browser can *navigate* to each
  # file rather than fetch() it — an authenticated fetch is a preflighted CORS
  # request, and the storage origin has no CORS rule for our origins.
  def download_url
    unless @printable.complete? && @printable.files.attached?
      return render json: { error: "Printable not ready" }, status: :not_found
    end

    render json: { files: @printable.files_view }
  end

  private

  def set_printable
    @printable = BoardPrintable.find_by(id: params[:id])
    return if @printable

    render json: { error: "Printable not found" }, status: :not_found
  end

  def include_subboards?
    return @include_subboards if defined?(@include_subboards)

    @include_subboards = ActiveModel::Type::Boolean.new.cast(params[:include_subboards]) || false
  end

  # Clamped rather than trusted: every board in the tree is two Chrome
  # renders, so an unbounded value is a way to hang a worker by typo.
  def max_boards
    @max_boards ||= begin
      requested = params[:max_boards].presence&.to_i || BoardPrintable::DEFAULT_MAX_BOARDS
      requested.clamp(1, BoardPrintable::MAX_BOARDS_CEILING)
    end
  end
end
