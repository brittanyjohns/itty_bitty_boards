require "set"

module Boards
  # Assembles a whole board set as a graph: every member board with its tiles,
  # plus the folder→child edges, with depth / reachability / duplicate-word
  # stats precomputed server-side. The frontend "bird's-eye map" renders this
  # in one call — it never traverses the predictive links itself.
  #
  # v1 targets builder sets (the `predictive_board_id` tree keyed on a
  # BoardGroup), but the shape generalizes to any BoardGroup.
  class SetGraphBuilder
    # Defensive hard cap on the root-BFS fallback so a cyclic/garbage set can't
    # spin forever. Builder sets are tiny (root + ~a dozen pages).
    MAX_BOARDS = 500

    def initialize(board_group, viewing_user: nil)
      @board_group = board_group
      @viewing_user = viewing_user
    end

    def call
      boards = resolve_boards
      boards_by_id = boards.index_by(&:id)

      edges = build_edges(boards, boards_by_id)
      depth_by_id = compute_depths(edges)

      board_payloads = boards.map do |board|
        depth = depth_by_id[board.id]
        {
          id: board.id,
          name: board.name,
          depth: depth,
          reachable: !depth.nil?,
          tiles: board.board_images.map { |bi| tile_payload(bi) },
        }
      end

      {
        id: board_group.id,
        name: board_group.name,
        builder: board_group.builder?,
        root_board_id: root_board_id,
        stats: build_stats(board_payloads, depth_by_id),
        boards: board_payloads,
        edges: edges,
      }
    end

    private

    attr_reader :board_group, :viewing_user

    def root_board_id
      board_group.root_board_id
    end

    # Prefer post-#407 board_group membership. Fall back to a BFS from the root
    # board over predictive links for sets that predate the backfill, so the
    # endpoint still works on an unbackfilled set.
    def resolve_boards
      members = board_group.boards.includes(board_images: :image).to_a
      return members if members.present?

      bfs_boards_from_root
    end

    def bfs_boards_from_root
      return [] if root_board_id.blank?

      visited = {}
      queue = [root_board_id]
      until queue.empty? || visited.size >= MAX_BOARDS
        board_id = queue.shift
        next if visited.key?(board_id)

        board = Board.includes(board_images: :image).find_by(id: board_id)
        next unless board

        visited[board_id] = board
        board.board_images.each do |bi|
          target = bi.predictive_board_id
          queue << target if target.present? && target != bi.board_id && !visited.key?(target)
        end
      end
      visited.values
    end

    # Every tile with a non-null predictive_board_id whose target board is in
    # the set becomes a folder→child edge.
    def build_edges(boards, boards_by_id)
      edges = []
      boards.each do |board|
        board.board_images.each do |bi|
          target_id = bi.predictive_board_id
          next if target_id.blank?
          next unless boards_by_id.key?(target_id)

          edges << {
            from: board.id,
            to: target_id,
            via_tile_id: bi.id,
            via_label: tile_label(bi),
          }
        end
      end
      edges
    end

    # BFS from the root board over the edges. Boards in the set never reached
    # get no depth entry → nil depth / reachable: false downstream.
    def compute_depths(edges)
      depths = {}
      return depths if root_board_id.blank?

      adjacency = Hash.new { |h, k| h[k] = [] }
      edges.each { |e| adjacency[e[:from]] << e[:to] }

      depths[root_board_id] = 0
      queue = [root_board_id]
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

    def build_stats(board_payloads, depth_by_id)
      word_tiles = board_payloads.flat_map { |b| b[:tiles] }.reject { |t| t[:is_folder] }

      # Distinct word labels (case-insensitive) that land on 2+ distinct boards.
      label_board_ids = Hash.new { |h, k| h[k] = Set.new }
      board_payloads.each do |board|
        board[:tiles].each do |tile|
          next if tile[:is_folder]

          label = tile[:label].to_s.downcase.strip
          next if label.blank?

          label_board_ids[label] << board[:id]
        end
      end
      duplicate_words = label_board_ids.count { |_label, ids| ids.size >= 2 }

      {
        boards: board_payloads.size,
        words: word_tiles.size,
        max_depth: depth_by_id.values.max || 0,
        duplicate_words: duplicate_words,
        unreachable_boards: board_payloads.count { |b| !b[:reachable] },
      }
    end

    def tile_payload(board_image)
      {
        id: board_image.id,
        label: tile_label(board_image),
        image_url: board_image.display_image_url,
        links_to_board_id: board_image.predictive_board_id,
        is_folder: board_image.predictive_board_id.present?,
      }
    end

    def tile_label(board_image)
      board_image.display_label.presence || board_image.label
    end
  end
end
