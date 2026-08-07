module Boards
  module AdminBuilder
    # The authored board set, normalized: the root page plus any child pages,
    # all in the same shape so validation, preview and build can iterate one
    # list instead of special-casing the root everywhere.
    #
    # A page is `{ key:, name:, columns:, rows:, tiles: }`; a tile is
    # `{ label:, part_of_speech:, display_label:, links_to: }`. The root's key
    # is ROOT_KEY, which is also what a child's "back to home" tile links to.
    #
    # Children inherit the root's grid unless they carry their own — every board
    # in a set shares the root's grid, so a communicator moving into a folder
    # page doesn't have the cell size change under their finger.
    module Plan
      ROOT_KEY = "__root__".freeze

      module_function

      # `root` is `{ name:, columns:, rows:, tiles: }`; each child adds `key:`
      # and may override `columns`/`rows`.
      def pages(root:, children: [])
        root_page = {
          key: ROOT_KEY,
          name: root[:name].to_s,
          columns: root[:columns].to_i,
          rows: root[:rows].to_i,
          tiles: Array(root[:tiles]),
        }

        [root_page] + Array(children).map { |child| child_page(child, root_page) }
      end

      def child_page(child, root_page)
        {
          key: child[:key].to_s.strip,
          name: child[:name].to_s,
          columns: child[:columns].presence&.to_i || root_page[:columns],
          rows: child[:rows].presence&.to_i || root_page[:rows],
          tiles: Array(child[:tiles]),
          # Whether the grid was authored on this page or inherited — the
          # mixed-grid check only has something to say about an authored one.
          inherits_grid: child[:columns].blank? && child[:rows].blank?,
        }
      end

      def root?(page)
        page[:key] == ROOT_KEY
      end

      # Every label across the set, deduped case-insensitively — what art
      # resolution works from.
      def labels(pages)
        pages.flat_map { |page| page[:tiles].map { |tile| tile[:label].to_s } }
             .reject(&:blank?)
             .uniq { |label| label.downcase }
      end

      # Round-trips a stored `plan` jsonb back into page hashes.
      def from_stored(stored, name:, columns:, rows:)
        stored = stored || {}

        pages(
          root: { name: name, columns: columns, rows: rows, tiles: symbolize_tiles(stored["tiles"]) },
          children: Array(stored["children"]).map do |child|
            {
              key: child["key"],
              name: child["name"],
              columns: child["columns"],
              rows: child["rows"],
              tiles: symbolize_tiles(child["tiles"]),
            }
          end,
        )
      end

      def symbolize_tiles(tiles)
        Array(tiles).map do |tile|
          {
            label: tile["label"].to_s,
            part_of_speech: tile["part_of_speech"].presence || "default",
            display_label: tile["display_label"].presence,
            links_to: tile["links_to"].presence,
          }.compact
        end
      end

      def stringify_tiles(tiles)
        Array(tiles).map { |tile| tile.transform_keys(&:to_s).compact }
      end
    end
  end
end
