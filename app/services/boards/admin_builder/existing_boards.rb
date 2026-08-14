module Boards
  module AdminBuilder
    # Published admin boards a page could point at instead of building a new one.
    #
    # A set's pages repeat across topics — most park, zoo and grocery boards want
    # a "Feelings" page, and the drafter cheerfully invents a worse one every
    # time. Offering the board that already exists is how the good one gets
    # reused; building a new page stays the default, because a page tuned to
    # this set's reading level is often still the right answer.
    module ExistingBoards
      # Per page name. Enough to recognise the right board, few enough to stay a
      # dropdown rather than a search screen.
      MAX_MATCHES = 5

      module_function

      # What may be linked. Deliberately NOT `Board.public_boards`: that scope
      # requires `predefined`, and admin Board Builder boards are pointedly not
      # predefined (see Build#new_board), so it would hide exactly the boards
      # this page produces.
      #
      # Predictive boards are excluded because `BoardImage#door_tile?` reads a
      # tile pointing at one as a dynamic WORD tile, not a folder — linking one
      # would build a door that doesn't behave like a door.
      def scope
        Board.where(user_id: User::DEFAULT_ADMIN_ID, published: true)
             .where("boards.board_type IS DISTINCT FROM 'menu'")
             .where("boards.board_type IS DISTINCT FROM 'predictive'")
             .where.not(parent_type: "Menu")
      end

      # Re-resolved from the scope rather than trusted: the id arrives on a form
      # post, and `Board.find` on a raw param would let a hand-edited value
      # point a published admin set at anyone's board.
      def find(id)
        return nil if id.blank?

        scope.find_by(id: id.to_i)
      end

      # `{ "feelings" => [Match, ...] }`, keyed by the downcased page name so the
      # view can look up each page block by the name in it. One query for every
      # page on the form, plus one for the tile counts.
      def matching(names, columns: nil)
        wanted = Array(names).filter_map { |name| name.to_s.strip.downcase.presence }.uniq
        return {} if wanted.empty?

        boards = scope.where("lower(boards.name) IN (?)", wanted).to_a
        return {} if boards.empty?

        counts = tile_counts(boards.map(&:id))

        boards.group_by { |board| board.name.to_s.downcase }
              .transform_values do |list|
                rank(list, columns).first(MAX_MATCHES).map { |board| Match.new(board, counts[board.id].to_i) }
              end
      end

      # Same grid first, then most recently touched — the board someone has been
      # maintaining is the one worth reusing.
      def rank(boards, columns)
        boards.sort_by do |board|
          [board.large_screen_columns.to_i == columns.to_i ? 0 : 1, -board.updated_at.to_i]
        end
      end

      # `reorder(nil)` is required, not tidy-up: BoardImage carries a default
      # order on `position`, and Postgres rejects a GROUP BY whose ORDER BY
      # names a column that is neither grouped nor aggregated.
      def tile_counts(board_ids)
        BoardImage.where(board_id: board_ids).reorder(nil).group(:board_id).count
      end

      # What the picker needs to say, without the view reaching into a Board and
      # firing a count per option.
      Match = Struct.new(:board, :tile_count) do
        def id = board.id
        def name = board.name
        def slug = board.slug
        def columns = board.large_screen_columns.to_i

        def same_grid?(other_columns) = columns == other_columns.to_i

        def summary
          "#{columns} cols · #{tile_count} #{"tile".pluralize(tile_count)} · /pb/#{slug}"
        end
      end
    end
  end
end
