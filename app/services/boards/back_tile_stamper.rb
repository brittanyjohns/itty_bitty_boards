module Boards
  # Marks the tiles in a board set that navigate BACK or SIDEWAYS, so structural
  # walks can tell them from a folder tile that descends into a subboard.
  #
  # Direction is read off Boards::SetDepths: a link that doesn't get you further
  # from the home board isn't a descent. That covers a go-back-to-root tile, a
  # go-back-to-parent tile several levels down, and a nav row's sibling links,
  # without needing any of them to have been flagged at creation time — which
  # matters because OBF/OBZ import creates a back button as a plain folder tile
  # with no flags at all.
  #
  # A board nothing links to has NO depth entry and is treated as infinitely
  # deep, so every link off it counts as a way back. That is the right call: an
  # unreachable page is not the parent of anything it points at.
  #
  # Idempotent — a tile already carrying the flag is skipped — so it is safe to
  # re-run after an import or a re-sync.
  class BackTileStamper
    def initialize(board_group, dry_run: false)
      @board_group = board_group
      @dry_run = dry_run
    end

    # => Array<BoardImage> — the tiles that were (or would be) stamped.
    def call
      return [] if board_group.blank? || board_group.root_board_id.blank?

      candidates.each do |board_image|
        next if dry_run

        board_image.update_column(:data, (board_image.data || {}).merge("back_tile" => true))
      end
    end

    private

    attr_reader :board_group, :dry_run

    def set_depths
      @set_depths ||= Boards::SetDepths.new(board_group)
    end

    def depths
      @depths ||= set_depths.call
    end

    def candidates
      # reorder(nil): board_images carries a default position ordering that
      # breaks batched queries.
      @candidates ||= BoardImage
        .where(board_id: set_depths.member_ids)
        .where.not(predictive_board_id: nil)
        .reorder(nil)
        .select { |bi| non_descending?(bi) }
    end

    def non_descending?(board_image)
      return false if board_image.predictive_board_id == board_image.board_id
      return false if BoardImage.back_tile_data?(board_image.data)

      target_depth = depths[board_image.predictive_board_id]
      return false if target_depth.nil? # points out of the set, or at an unreachable board

      target_depth <= (depths[board_image.board_id] || Float::INFINITY)
    end
  end
end
