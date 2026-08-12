module Boards
  # How far each board in a set sits from the set's home board, measured in
  # folder-tile hops. Shared by Boards::SetGraphBuilder (which renders it as the
  # bird's-eye map's "Home / Depth 1 / Depth 2 / Not linked" bands) and by
  # Boards::BackTileStamper (which uses it to tell a descent from a way back).
  #
  # A board the walk never reaches gets NO entry — that is the map's "not linked
  # to home", and callers must treat it as deeper than anything, not as depth 0.
  class SetDepths
    # `edges` is optional: pass the ones SetGraphBuilder already built to avoid
    # a second pass over the tiles.
    def initialize(board_group, edges: nil)
      @board_group = board_group
      @edges = edges
    end

    # => { board_id => Integer }, root at 0.
    def call
      root_id = board_group.root_board_id
      return {} if root_id.blank?

      adjacency = Hash.new { |h, k| h[k] = [] }
      edges.each { |e| adjacency[e[:from]] << e[:to] }

      depths = { root_id => 0 }
      queue = [root_id]
      until queue.empty?
        current = queue.shift
        adjacency[current].each do |neighbor|
          next if depths.key?(neighbor)

          depths[neighbor] = depths[current] + 1
          queue << neighbor
        end
      end
      depths
    end

    # Prefer board_group membership; fall back to a walk from the root for sets
    # that predate the #407 membership backfill, matching SetGraphBuilder.
    def member_ids
      @member_ids ||= resolve_member_ids
    end

    private

    attr_reader :board_group

    def resolve_member_ids
      ids = board_group.board_group_boards.reorder(nil).pluck(:board_id)
      return ids if ids.present?

      root = Board.find_by(id: board_group.root_board_id)
      root ? Boards::LinkedBoardsFinder.new(root).call.map(&:id) : []
    end

    # Folder→child links between two boards that are both IN the set. Links out
    # of the set can't contribute depth and are dropped.
    def edges
      @edges ||= begin
        member_id_set = member_ids.to_set

        BoardImage
          .where(board_id: member_ids)
          .where.not(predictive_board_id: nil)
          .reorder(nil)
          .pluck(:board_id, :predictive_board_id)
          .filter_map do |from, to|
            { from: from, to: to } if member_id_set.include?(to)
          end
      end
    end
  end
end
