module Boards
  # Hard-deletes a LEGACY per-communicator assignment template and its
  # sub-boards, when nothing else references them.
  #
  # Assignment no longer mints these — it attaches the board itself — but every
  # dashboard populated before that change holds an `is_template: true` clone
  # that only its own dashboard tile can reach. Two callers need identical
  # deletion rules: detaching such a tile
  # (API::ChildBoardsController#destroy) and consolidating one onto its source
  # (rake board_assignments:consolidate). Keeping two copies of the guards is
  # how one of them ends up deleting a team's board.
  #
  #   Boards::AssignmentTemplateSweep.new(board, actor_id: user.id).call
  #   # => number of boards destroyed (0 when the root is not an orphan)
  #
  # `actor_id` is who must OWN a board for it to be deletable — never inferred,
  # because a nil actor plus a `user_id == nil` row would match.
  class AssignmentTemplateSweep
    def initialize(root_board, actor_id:)
      @root_board = root_board
      @actor_id = actor_id
    end

    def call
      return 0 if @root_board.nil?
      return 0 unless @root_board.is_template?
      return 0 if @actor_id.nil?
      return 0 unless orphan?(@root_board)

      # Collect the sub-clones BEFORE the root goes: they are found by the root
      # clone's id, which stops being resolvable once it is destroyed.
      sweepable = sub_templates(@root_board)
      destroyed = 0

      @root_board.destroy
      destroyed += 1
      destroyed + sweep!(sweepable)
    end

    # A template clone is safe to hard-delete only when nothing else references
    # it: not shared as a team board, not on any other communicator's dashboard,
    # not opened by a folder tile on some other board, and owned by the actor.
    # Anything else detaches only, so clearing one dashboard can never destroy
    # content another surface depends on.
    def orphan?(board)
      return false if board.team_boards.exists?
      return false if board.child_boards.exists?
      return false if BoardImage.where(predictive_board_id: board.id).where.not(board_id: board.id).exists?

      board.user_id == @actor_id
    end

    private

    # Sub-board clones Boards::SetCloner minted for this root.
    def sub_templates(root_board)
      Board.where(user_id: @actor_id, is_template: true)
           .where("settings->>'assignment_root_id' = ?", root_board.id.to_s)
           .to_a
    end

    # Nested folders reference each other, so destroying a parent frees its
    # children — iterate until a pass deletes nothing. (A reference cycle
    # between two sub-boards leaves both in place; acceptable, they are
    # invisible template rows.)
    def sweep!(sweepable)
      destroyed = 0
      until sweepable.empty?
        deletable = sweepable.select { |b| orphan?(b) }
        break if deletable.empty?

        deletable.each do |board|
          Rails.logger.info "[AssignmentTemplateSweep] destroying orphaned sub-template board #{board.id}"
          board.destroy
          destroyed += 1
        end
        sweepable -= deletable
      end
      destroyed
    end
  end
end
