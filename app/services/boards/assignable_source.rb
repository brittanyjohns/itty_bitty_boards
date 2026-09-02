module Boards
  # Which boards may be put on a communicator's dashboard, and where each one
  # came from.
  #
  # Assignment ATTACHES a board — it no longer clones one — so this allowlist is
  # load-bearing in a way it was not before. `assign_boards` used to resolve an
  # id with a bare `Board.find`, and the damage was bounded only because the
  # result was an invisible per-communicator copy. Attaching the row itself
  # makes an unchecked id a straight read of another user's private board.
  #
  #   Boards::AssignableSource.new(child_account, actor: current_user).resolve(id)
  #   # => [board, :own] | [board, :public] | [board, :team] | nil
  #
  # The actor is the person doing the assigning, who is not necessarily the
  # communicator's owner — a team supervisor may curate a dashboard. Both sides'
  # own boards count: the supervisor's, because sharing their board is the
  # point, and the OWNER's, because curating is done on the owner's behalf and
  # putting the family's own board on the family's own dashboard cannot expose
  # anything. Whether this person may curate at all is already settled by
  # `authorize_communicator_curate!` before we get here.
  class AssignableSource
    def initialize(child_account, actor:)
      @child_account = child_account
      @actor = actor
    end

    # nil means "not assignable" and callers must answer with a generic 422:
    # never say whether the id exists, or this becomes an existence oracle for
    # other people's boards.
    def resolve(board_id)
      id = board_id.to_i
      return nil if id.zero?

      if (board = own_scope.find_by(id: id))
        [board, :own]
      elsif (board = Board.public_boards.find_by(id: id))
        [board, :public]
      elsif (board = team_scope.find_by(id: id))
        [board, :team]
      end
    end

    private

    # `is_template: false` mirrors the `user.boards` association and keeps a
    # legacy assignment clone from being re-attached to a second dashboard.
    def own_scope
      return Board.none if @actor.nil?
      return Board.where(is_template: false) if @actor.try(:admin?)

      owner_ids = [@actor.id, @child_account&.user_id].compact.uniq
      Board.where(user_id: owner_ids, is_template: false)
    end

    def team_scope
      return Board.none if @child_account.nil?

      Board.where(id: TeamBoard.where(team_id: @child_account.teams.select(:id)).select(:board_id))
    end
  end
end
