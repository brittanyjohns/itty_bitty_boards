module Boards
  # Shared helpers for working with a LINKED BOARD SET — the graph formed by
  # BoardImage#predictive_board_id folder-tile pointers. Extracted from
  # Boards::SeededSetCloner so the deep cloners (Boards::SetCloner) reuse the
  # same BFS + rewire instead of reimplementing them.
  module PredictiveLinkSet
    module_function

    # BFS over predictive_board_id links from the root, bounded to max_depth
    # and cycle-safe (visited set). A board reachable twice is collected once;
    # the root is first in the returned list. `exclude` (optional callable) can
    # veto non-root boards from the walk.
    #
    # `max_boards` caps how many boards come back. Depth alone does not bound
    # this walk — a shallow but WIDE graph (one board with 200 folder tiles) is
    # unbounded at any depth — and every caller hydrates the result, so the cap
    # is what keeps a pathological set from loading the whole table. nil means
    # no cap, which is what the callers that predate it already assumed.
    # Boards::ExportScope applies its own cap downstream for the same reason.
    def collect(root, max_depth:, max_boards: nil, exclude: nil)
      visited = {}
      ordered = []
      queue   = [[root, 0]]

      until queue.empty?
        break if max_boards && ordered.size >= max_boards

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
    #   :null    — nulled (builder sets: never leave a user tile opening an
    #              admin-owned seed board)
    #   :keep    — left verbatim (assignment: arbitrary user sets; a link past
    #              the depth cap keeps working exactly as before)
    #   :flatten — turned into an ordinary speaking tile
    #              (BoardImage#flatten_navigation!). This is :null plus the
    #              navigation DATA keys — mute_name, the nav-tile and back-tile
    #              markers. Nulling the column alone leaves those behind, so
    #              BoardImage#door_tile? still reports a door and the board-set
    #              map still draws a folder edge to nothing. Anything a USER
    #              copies into their own account wants this: the tile can't
    #              open a board that wasn't copied, and it must not keep
    #              pointing into the source owner's live account either.
    #
    # Returns the number of out-of-set pointers it acted on (0 under :keep).
    def rewire!(map, out_of_set: :null)
      out_of_set_count = 0

      map.each_value do |cloned|
        cloned.board_images.where.not(predictive_board_id: nil).find_each do |bi|
          target = map[bi.predictive_board_id]
          if target
            bi.update!(predictive_board_id: target.id)
            next
          end

          case out_of_set
          when :null
            bi.update!(predictive_board_id: nil)
            out_of_set_count += 1
          when :flatten
            bi.flatten_navigation!
            bi.save!
            out_of_set_count += 1
          end
        end
      end

      out_of_set_count
    end
  end
end
