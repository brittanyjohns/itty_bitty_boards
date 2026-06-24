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

    # Groups of >1 tiles sharing a normalized label AND kind, each sorted so the
    # tile to KEEP is first. Grouping on (label, folder?) keeps a word tile
    # ("play") distinct from its same-named category folder ("Play") — those are
    # intentionally separate tiles, not duplicates.
    def duplicate_groups(board)
      board.board_images.includes(:image).group_by { |bi| group_key(bi) }
           .reject { |(label, _folder), tiles| label.blank? || tiles.size < 2 }
           .transform_values { |tiles| tiles.sort_by { |bi| [bi.position || Float::INFINITY, bi.id] } }
    end

    def group_key(board_image)
      label = (board_image.label.presence || board_image.image&.label).to_s.strip.downcase
      [label, board_image.predictive_board_id.present?]
    end
    private_class_method :group_key
  end
end
