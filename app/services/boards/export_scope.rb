module Boards
  # Resolves an export request into the boards to include, the root, and the
  # boards deliberately left out.
  #
  # Boards::PredictiveLinkSet.collect is bounded by max_depth ONLY — it has no
  # board-count limit (MAX_BOARDS on SetGraphBuilder is a different service).
  # A wide, shallow link graph would otherwise produce an unbounded package, so
  # this service imposes its own count cap on top of the depth cap.
  class ExportScope
    MAX_BOARDS = 200
    MAX_DEPTH = 6

    Result = Struct.new(:boards, :root, :skipped_boards)

    class << self
      # A board plus everything reachable through its predictive links.
      def for_board(board, exporting_user:)
        skipped = []

        collected = PredictiveLinkSet.collect(
          board,
          max_depth: MAX_DEPTH,
          exclude: ->(candidate) do
            next false if candidate.viewable_by?(exporting_user)

            skipped << { board_id: candidate.id, reason: "not readable by the exporting user" }
            true
          end,
        )

        capped, overflow = cap(collected)
        overflow.each { |b| skipped << { board_id: b.id, reason: "package board limit reached" } }
        skipped.uniq! { |s| s[:board_id] }

        Result.new(capped, board, skipped)
      end

      # An explicit Board Set. Membership is already curated, so there is no
      # link walking — only the read check and the count cap.
      def for_group(board_group, exporting_user:)
        skipped = []
        members = board_group.boards.to_a

        readable = members.select do |b|
          next true if b.viewable_by?(exporting_user)

          skipped << { board_id: b.id, reason: "not readable by the exporting user" }
          false
        end

        root = board_group.root_board if board_group.root_board_id.present?
        root = readable.first unless root && readable.any? { |b| b.id == root.id }

        ordered = readable.sort_by { |b| b.id == root&.id ? 0 : 1 }
        capped, overflow = cap(ordered)
        overflow.each { |b| skipped << { board_id: b.id, reason: "package board limit reached" } }
        skipped.uniq! { |s| s[:board_id] }

        Result.new(capped, root, skipped)
      end

      private

      def cap(boards)
        [boards.first(MAX_BOARDS), boards.drop(MAX_BOARDS)]
      end
    end
  end
end
