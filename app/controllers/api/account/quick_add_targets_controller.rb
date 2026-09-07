# Which boards a COMMUNICATOR may quick-add a word to.
#
# A dedicated controller rather than another action on
# API::Account::BoardsController: that one renders bare ActiveRecord objects
# (every column, no ownership discipline), and this payload has a leak rule to
# hold — a communicator learns that someone else uses a board, never who.
#
# The set comes from Boards::QuickAddScope, the same object
# check_communicator_board_access! consults, so anything offered here is
# writable and anything missing is refused there.
class API::Account::QuickAddTargetsController < API::Account::ApplicationController
  respond_to :json
  before_action :authenticate_child_token!, only: %i[index]

  # GET /api/account/quick_add_targets
  def index
    scope = Boards::QuickAddScope.new(current_account)
    boards_by_id = scope.boards.index_by(&:id)

    render json: {
      boards: scope.board_ids.filter_map { |id|
        boards_by_id[id]&.quick_add_card_view(scope)
      },
      # A truncated walk still leaves the picker and the gate agreeing: both
      # read this same prefix. The client says "some boards aren't listed"
      # rather than failing — usage must never break.
      truncated: scope.truncated?,
      limit: Boards::QuickAddScope.max_boards,
    }
  end
end
