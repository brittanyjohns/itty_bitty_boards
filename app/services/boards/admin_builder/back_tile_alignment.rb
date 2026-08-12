module Boards
  module AdminBuilder
    # Puts a page's way home WHERE THE WAY IN WAS: the back tile occupies the
    # same grid cell as the folder tile that opens the page from its parent.
    #
    # Muscle memory is the whole point. A communicator who taps "Food" at the
    # third cell of the bottom row should find "back" at the third cell of the
    # bottom row, on every page, at every depth — not have to re-scan the grid
    # because the drafter happened to write the back tile last.
    #
    # Nothing here touches the database. Admin builds lay tiles out in pure
    # authored reading order (`Build#apply_reading_order!`: `x = i % columns`,
    # `y = i / columns`), so a parent's folder-tile CELL is already known from
    # that tile's INDEX in the parent page's list. The whole alignment is
    # therefore a permutation over the plan, which is also what lets
    # `ArtPreview` show the admin the layout that will actually be built.
    #
    # The move is a SWAP, not an insert: both tiles are 1x1, so trading cells
    # keeps the grid fully packed and hands the displaced word the corner the
    # back tile vacated. Inserting would open a hole and shift every tile after
    # it.
    module BackTileAlignment
      module_function

      # `{ page_key => [cell_index, ...] }` — entry `i` is the grid cell tile
      # `i` should occupy. Identity for any page with nothing to align.
      def cell_indexes(pages)
        pages = Array(pages)
        parents = parent_links(pages)

        pages.to_h do |page|
          [page[:key], page_cells(page, pages, parents)]
        end
      end

      # Which tile opens each page, and from where: `{ page_key => { page:, index: } }`.
      #
      # BFS from the root so the SHALLOWEST parent wins when two pages link the
      # same child — the way in a communicator is most likely to have taken.
      # Pages unreachable from the root get no entry and are left alone.
      def parent_links(pages)
        by_key = pages.index_by { |page| page[:key] }
        root = by_key[Plan::ROOT_KEY]
        return {} if root.nil?

        links = {}
        queue = [root]
        seen = Set.new([root[:key]])

        while (page = queue.shift)
          page[:tiles].each_with_index do |tile, index|
            target = tile[:links_to].presence
            next if target.nil? || target == page[:key] || seen.include?(target)

            child = by_key[target]
            next if child.nil?

            seen << target
            links[target] = { page: page, index: index }
            queue << child
          end
        end

        links
      end

      def page_cells(page, pages, parents)
        identity = (0...page[:tiles].size).to_a
        link = parents[page[:key]]
        return identity if link.nil?

        back = back_tile_index(page, link[:page])
        return identity if back.nil?

        target = mirrored_index(page, link)
        return identity if target.nil? || target == back

        identity.tap do |cells|
          cells[back], cells[target] = cells[target], cells[back]
        end
      end

      # The tile that goes back. Prefer one pointing at this page's actual
      # parent; fall back to ROOT_KEY, which is what the drafters ask for
      # (`SetDrafter`/`PageDrafter`: "one tile that goes back") and therefore
      # what a second-level page usually carries.
      def back_tile_index(page, parent)
        index_of_link(page, parent[:key]) || index_of_link(page, Plan::ROOT_KEY)
      end

      def index_of_link(page, target)
        page[:tiles].index { |tile| tile[:links_to].presence == target }
      end

      # The parent's cell, clamped into this page's grid. A page can carry its
      # own `columns` (mixed grids are allowed) and is usually shorter than the
      # root, so both axes have to be brought back in range — and the final
      # clamp handles a ragged last row, where the mirrored column doesn't
      # exist yet.
      def mirrored_index(page, link)
        parent_columns = link[:page][:columns].to_i
        columns = page[:columns].to_i
        count = page[:tiles].size
        return nil if parent_columns < 1 || columns < 1 || count.zero?

        x = [link[:index] % parent_columns, columns - 1].min
        y = [link[:index] / parent_columns, (count - 1) / columns].min

        [(y * columns) + x, count - 1].min
      end
    end
  end
end
