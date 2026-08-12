module Boards
  # Id-only BFS over folder→child links (board_images.predictive_board_id),
  # one query per level. Built for structural questions — "what hangs off this
  # board?" — where the boards themselves aren't needed, only their ids.
  #
  # Boards::LinkedBoardsFinder is the hydrated-Board equivalent and stays as-is:
  # SetGraphBuilder and BoardGroupCreator want the records and the complete
  # graph. This one can skip back tiles and exclude ids mid-walk, which those
  # callers must not do.
  class ReachableBoardIds
    # Defensive hard cap so a cyclic/garbage tree can't spin forever. Higher
    # than LinkedBoardsFinder's because id rows are far cheaper than boards.
    MAX_BOARDS = 2000

    def initialize(seed_ids, exclude_ids: [], skip_back_tiles: false, limit: MAX_BOARDS)
      @seed_ids = Array(seed_ids).compact.uniq
      @exclude_ids = Array(exclude_ids).compact.to_set
      @skip_back_tiles = skip_back_tiles
      @limit = limit
    end

    # Board ids in BFS order, seeds first. Excluded ids are never entered and
    # never expanded through.
    def ids
      walk
      @ids
    end

    # True when the walk hit the cap and the result is therefore incomplete.
    # Callers making a safety decision must treat this as "I don't know".
    def truncated?
      walk
      @truncated
    end

    private

    attr_reader :seed_ids, :exclude_ids, :skip_back_tiles, :limit

    def walk
      return if defined?(@ids)

      visited = seed_ids.reject { |id| exclude_ids.include?(id) }
      seen = visited.to_set
      frontier = visited
      @truncated = false

      until frontier.empty? || seen.size >= limit
        next_frontier = []
        links_from(frontier).each do |source_id, target_id, data|
          next if target_id == source_id
          next if seen.include?(target_id) || exclude_ids.include?(target_id)
          next if skip_back_tiles && BoardImage.back_tile_data?(data)

          seen << target_id
          visited << target_id
          next_frontier << target_id
        end
        frontier = next_frontier
      end

      @truncated = true if seen.size >= limit && frontier.any?
      @ids = visited
    end

    # reorder(nil): board_images carries a default position ordering that breaks
    # a batched pluck.
    def links_from(board_ids)
      BoardImage
        .where(board_id: board_ids)
        .where.not(predictive_board_id: nil)
        .reorder(nil)
        .pluck(:board_id, :predictive_board_id, :data)
    end
  end
end
