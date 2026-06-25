module Boards
  # Collapses duplicate tiles a buggy re-import/re-seed appended to a board.
  #
  # Background: Board.upsert_board_image used to key on the resolved image_id, so
  # when find_or_create_image_for_button resolved the SAME authored button to a
  # different Image across runs (label+obf_id drift in the source OBF), the
  # upsert forked a brand-new tile instead of updating the existing one. That's
  # how the Core 60 builder source grew a second "all done" word tile, which then
  # cloned into every built set (the "extra all done" bug). The structural fix
  # lives in Board.upsert_board_image (now keyed on the stable OBF button id);
  # this collapses the duplicates that already landed.
  #
  # Safe to run on any board: it only ever removes EXTRA tiles that share a label
  # AND a kind (word vs folder), keeping the authored-position one.
  module TileDeduper
    module_function

    SCREEN = "lg".freeze

    # Returns the number of duplicate tiles removed (0 when the board is clean).
    # dry_run: report-only — counts what WOULD be removed without destroying.
    def collapse_duplicates!(board, dry_run: false)
      removed = 0

      duplicate_groups(board).each do |_key, tiles|
        # Keep the authored-position tile (lowest position, oldest id as a
        # tiebreak); the rest are appended duplicates.
        tiles.drop(1).each do |tile|
          tile.destroy unless dry_run
          removed += 1
        end
      end

      removed
    end

    # The ids collapse_duplicates! would destroy (every tile after the kept one
    # in each duplicate group). Lets a dry-run preview sequence dedupe→repack
    # without mutating: the repacker can ignore these so it doesn't count an
    # off-grid duplicate as a genuine overflow tile.
    def removable_tile_ids(board)
      duplicate_groups(board).flat_map { |_key, tiles| tiles.drop(1).map(&:id) }
    end

    # Groups of >1 tiles sharing a normalized label AND kind, each sorted so the
    # tile to KEEP is first. Grouping on (label, folder?) keeps a word tile
    # ("play") distinct from its same-named category folder ("Play") — those are
    # intentionally separate tiles, not duplicates.
    #
    # Keep-order: an IN-GRID tile (its lg cell fits the board's column count)
    # always wins over an out-of-grid one, THEN lowest position, THEN oldest id.
    # The in-grid rule matters because a builder bug can leave the lower-position
    # copy of a duplicate folder tile parked PAST the grid edge (e.g. a Core 84
    # "More" folder at x=13 on a 12-column board); blindly keeping the
    # lowest-position tile would preserve the broken off-grid copy and delete the
    # authored in-grid one — leaving the Speak view rendering wider than the grid.
    def duplicate_groups(board)
      columns = board_columns(board)
      board.board_images.includes(:image).group_by { |bi| group_key(bi) }
           .reject { |(label, _folder), tiles| label.blank? || tiles.size < 2 }
           .transform_values { |tiles| tiles.sort_by { |bi| keep_order(bi, columns) } }
    end

    def keep_order(board_image, columns)
      [in_grid?(board_image, columns) ? 0 : 1, board_image.position || Float::INFINITY, board_image.id]
    end
    private_class_method :keep_order

    # True when the tile's lg cell sits fully within the configured columns.
    def in_grid?(board_image, columns)
      cell = board_image.layout.is_a?(Hash) ? board_image.layout[SCREEN] : nil
      return true if cell.nil? # no lg layout → not the off-grid culprit; don't penalize

      x = cell["x"].to_i
      w = [cell["w"].to_i, 1].max
      (x + w) <= columns
    end
    private_class_method :in_grid?

    def board_columns(board)
      cols = board.large_screen_columns.to_i
      cols = board.number_of_columns.to_i if cols < 1
      cols < 1 ? 12 : cols
    end
    private_class_method :board_columns

    def group_key(board_image)
      label = (board_image.label.presence || board_image.image&.label).to_s.strip.downcase
      [label, board_image.predictive_board_id.present?]
    end
    private_class_method :group_key
  end
end
