module Boards
  # BFS over folder→child links (board_images.predictive_board_id) starting
  # at a given board. Used by Boards::SetGraphBuilder (root-BFS fallback for
  # sets that predate #407's board_group membership backfill) and by
  # Boards::BoardGroupCreator (auto-populating a brand new group).
  class LinkedBoardsFinder
    # Defensive hard cap so a cyclic/garbage tree can't spin forever.
    MAX_BOARDS = 500

    def initialize(root_board)
      @root_board = root_board
    end

    def call
      return [] if root_board.blank?

      visited = {}
      queue = [root_board.id]
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

    private

    attr_reader :root_board
  end
end
