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

    # `admit` is an optional callable receiving a LEVEL's candidate ids and
    # returning the subset that may be entered and expanded through. It is what
    # lets a caller make the walk answer a permission question — a folder tile
    # may point anywhere (board_images_controller permits predictive_board_id
    # without validating the target), so a walk used to decide access has to
    # refuse to follow a pointer rather than trust it. Called ONCE PER LEVEL,
    # never per id: a per-id callback would put a query on every node.
    #
    # `max_depth` bounds LEVELS. `limit` bounds NODES, which is a different
    # question — a deep thin chain is few nodes and one query per level, so
    # depth is what actually multiplies queries.
    #
    # `track_origins` records which seed(s) each id descends from, so a caller
    # can attribute a page to the root(s) that reach it.
    def initialize(seed_ids, exclude_ids: [], skip_back_tiles: false,
                   limit: MAX_BOARDS, max_depth: nil, admit: nil,
                   track_origins: false)
      @seed_ids = Array(seed_ids).compact.uniq
      @exclude_ids = Array(exclude_ids).compact.to_set
      @skip_back_tiles = skip_back_tiles
      @limit = limit
      @max_depth = max_depth
      @admit = admit
      @track_origins = track_origins
    end

    # Board ids in BFS order, seeds first. Excluded ids are never entered and
    # never expanded through; neither are ids `admit` refuses.
    def ids
      walk
      @ids
    end

    # True when the walk hit the node cap or the depth cap and the result is
    # therefore incomplete. Callers making a safety decision must treat this as
    # "I don't know".
    def truncated?
      walk
      @truncated
    end

    # { board_id => Set[seed_id, ...] }. Empty unless track_origins.
    def origins
      walk
      @origins
    end

    # The seed ids this id descends from (a seed descends from itself).
    def origins_for(id)
      origins.fetch(id, Set.new)
    end

    private

    attr_reader :seed_ids, :exclude_ids, :skip_back_tiles, :limit,
                :max_depth, :admit, :track_origins

    def walk
      return if defined?(@ids)

      @truncated = false
      @origins = {}
      @edges = []

      seeds = admitted(seed_ids.reject { |id| exclude_ids.include?(id) })
      visited = seeds.dup
      seen = seeds.to_set
      seeds.each { |id| @origins[id] = Set[id] } if track_origins

      frontier = seeds
      depth = 0

      until frontier.empty? || seen.size >= limit
        if max_depth && depth >= max_depth
          @truncated = true
          break
        end

        candidates = []
        links_from(frontier).each do |source_id, target_id, data|
          next if target_id == source_id
          next if exclude_ids.include?(target_id)
          next if skip_back_tiles && BoardImage.back_tile_data?(data)

          candidates << [source_id, target_id]
        end

        allowed = admitted(candidates.map(&:last).uniq - seen.to_a).to_set

        next_frontier = []
        candidates.each do |source_id, target_id|
          already = seen.include?(target_id)
          next unless already || allowed.include?(target_id)

          @edges << [source_id, target_id] if track_origins
          next if already

          seen << target_id
          visited << target_id
          next_frontier << target_id
        end

        frontier = next_frontier
        depth += 1
      end

      @truncated = true if seen.size >= limit && frontier.any?
      propagate_origins if track_origins
      @ids = visited
    end

    # `admit` decides membership for a whole level at once. nil means "no
    # filter", which is what every caller that predates it assumes.
    def admitted(candidate_ids)
      return candidate_ids if admit.nil? || candidate_ids.empty?

      allowed = admit.call(candidate_ids).to_set
      candidate_ids.select { |id| allowed.include?(id) }
    end

    # BFS alone under-propagates origins across a diamond — a node first
    # reached at depth 2 from one seed never re-walks its own links when a
    # second seed reaches it at depth 3, so its descendants never learn about
    # that seed. The edge set is already in memory and small, so settle it
    # exactly rather than shipping an ordering artifact.
    def propagate_origins
      loop do
        changed = false
        @edges.each do |source_id, target_id|
          source = @origins[source_id]
          next if source.nil? || source.empty?

          target = (@origins[target_id] ||= Set.new)
          before = target.size
          target.merge(source)
          changed = true if target.size != before
        end
        break unless changed
      end
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
