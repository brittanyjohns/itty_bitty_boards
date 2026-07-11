module Boards
  # Read-only "who still references this board?" check backing the
  # warn+confirm delete flow. A board is in use when another board's folder
  # tile points at it (predictive_board_id), it sits on a communicator
  # dashboard (ChildBoard), it's shared with a team (TeamBoard), or it's the
  # root of a Board Builder set (deleting it takes the whole built tree).
  class UsageCheck
    # Counts in the summary are exact; name lists are capped so a widely
    # referenced board (e.g. a predefined one) can't blow up the payload.
    NAME_SAMPLE_LIMIT = 10

    def initialize(board)
      @board = board
    end

    def in_use?
      referencing_tiles.exists? ||
        board.child_boards.exists? ||
        board.team_boards.exists? ||
        builder_group.present?
    end

    def summary
      {
        referencing_boards: referencing_boards_summary,
        communicators: communicators_summary,
        teams: teams_summary,
        builder_set: builder_set_summary,
      }
    end

    # The builder BoardGroup that owns this board's built tree, when this
    # board is a Board Builder root. Deletion routes through the group so the
    # #407 cascade destroys the whole set instead of orphaning the children.
    def builder_group
      return @builder_group if defined?(@builder_group)
      @builder_group = board.builder_board_group
    end

    private

    attr_reader :board

    # Folder tiles on OTHER boards. A board's own tile pointing back at
    # itself (self-link) must never block deletion.
    def referencing_tiles
      # reorder(nil): BoardImage's default position ordering breaks
      # SELECT DISTINCT board_id.
      BoardImage.where(predictive_board_id: board.id).where.not(board_id: board.id).reorder(nil)
    end

    def referencing_boards_summary
      board_ids = referencing_tiles.distinct.pluck(:board_id)
      {
        count: board_ids.size,
        names: Board.where(id: board_ids.first(NAME_SAMPLE_LIMIT)).pluck(:name),
      }
    end

    def communicators_summary
      account_ids = board.child_boards.distinct.pluck(:child_account_id)
      {
        count: account_ids.size,
        names: ChildAccount.where(id: account_ids.first(NAME_SAMPLE_LIMIT)).pluck(:name),
      }
    end

    def teams_summary
      team_ids = board.team_boards.distinct.pluck(:team_id)
      {
        count: team_ids.size,
        names: Team.where(id: team_ids.first(NAME_SAMPLE_LIMIT)).pluck(:name),
      }
    end

    def builder_set_summary
      group = builder_group
      return nil unless group

      {
        root: true,
        board_group_id: group.id,
        name: group.name,
        member_board_count: group.board_group_boards.count,
      }
    end
  end
end
