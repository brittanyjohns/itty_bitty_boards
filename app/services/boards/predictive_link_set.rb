module Boards
  # Shared helpers for working with a LINKED BOARD SET — the graph formed by
  # BoardImage#predictive_board_id folder-tile pointers. Extracted from
  # Boards::SeededSetCloner so the assignment deep-clone
  # (Boards::AssignmentCloner) reuses the same BFS + rewire instead of
  # reimplementing them.
  module PredictiveLinkSet
    module_function

    # BFS over predictive_board_id links from the root, bounded to max_depth
    # and cycle-safe (visited set). A board reachable twice is collected once;
    # the root is first in the returned list. `exclude` (optional callable) can
    # veto non-root boards from the walk.
    def collect(root, max_depth:, exclude: nil)
      visited = {}
      ordered = []
      queue   = [[root, 0]]

      until queue.empty?
        board, depth = queue.shift
        next if board.nil? || visited[board.id]
        next if board.id != root.id && exclude&.call(board)

        visited[board.id] = true
        ordered << board
        next if depth >= max_depth

        board.board_images.where.not(predictive_board_id: nil).each do |bi|
          sub = Board.find_by(id: bi.predictive_board_id)
          queue << [sub, depth + 1] if sub
        end
      end

      ordered
    end

    # Clones copy predictive_board_id verbatim, so a cloned folder tile points
    # at the SOURCE sub-board. Translate every pointer through the map
    # ({ source_board_id => cloned Board }). Pointers that leave the set:
    #   :null — nulled (builder sets: never leave a user tile opening an
    #           admin-owned seed board)
    #   :keep — left verbatim (assignment: arbitrary user sets; a link past
    #           the depth cap keeps working exactly as before)
    def rewire!(map, out_of_set: :null)
      map.each_value do |cloned|
        cloned.board_images.where.not(predictive_board_id: nil).find_each do |bi|
          target = map[bi.predictive_board_id]
          if target
            bi.update!(predictive_board_id: target.id)
          elsif out_of_set == :null
            bi.update!(predictive_board_id: nil)
          end
        end
      end
    end
  end
end
