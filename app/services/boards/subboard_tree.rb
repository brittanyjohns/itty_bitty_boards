module Boards
  # Read-only "what would 'delete the subboards too' actually delete?" check.
  #
  # Walks the outbound folder→child links (board_images.predictive_board_id)
  # from a board being deleted and splits the resulting tree into boards that
  # are safe to cascade-delete and boards that must be KEPT because something
  # outside the tree still depends on them. Nothing here deletes — the caller
  # (Api::BoardsController#destroy) does that with #deletable_ids.
  #
  # Board Builder roots don't come through here: their tree is owned by a
  # builder BoardGroup and destroy routes through group.destroy! instead.
  class SubboardTree
    # Reasons a subboard is kept rather than cascaded. Surfaced in #summary so
    # the confirm dialog can explain what survives.
    KEPT_REASONS = %i[predefined not_owned on_communicator shared_with_team referenced_outside].freeze

    NAME_SAMPLE_LIMIT = 10

    def initialize(board, user: nil)
      @board = board
      @user = user || board.user
    end

    def any?
      tree.any?
    end

    def deletable_ids
      partition.fetch(:deletable).map(&:id)
    end

    def kept
      partition.fetch(:kept)
    end

    def summary
      return nil unless any?

      {
        total: tree.size,
        deletable_count: deletable_ids.size,
        kept_count: kept.size,
        names: tree.first(NAME_SAMPLE_LIMIT).map(&:name),
        kept_names: kept.first(NAME_SAMPLE_LIMIT).map { |k| k[:name] },
      }
    end

    private

    attr_reader :board, :user

    # Every board this one descends into through folder tiles.
    #
    # Two things keep the walk from climbing UP out of the board: it refuses to
    # follow a back tile (BoardImage.back_tile_data?), and it refuses to enter
    # the home board of any set this board belongs to. Without them, a child
    # page's "go back" tile leads to the set root and then back down across
    # every sibling, and the whole set reads as this page's subboards.
    #
    # Residual gap: a board in NO board group whose back tile was never flagged
    # has no directional signal at all — a symmetric pair of links is genuinely
    # ambiguous. The editor's "This tile goes back" toggle is the fix there.
    def tree
      @tree ||= begin
        walk = ReachableBoardIds.new([board.id], exclude_ids: set_root_ids, skip_back_tiles: true)
        # A truncated walk under-reports what is excluded, which is the unsafe
        # direction — offer no cascade rather than a wrong one.
        if walk.truncated?
          []
        else
          ids = walk.ids - [board.id]
          by_id = Board.where(id: ids).index_by(&:id)
          ids.filter_map { |id| by_id[id] }
        end
      end
    end

    # The home board of every set this board belongs to. Union across all
    # groups and deliberately not scoped to `user`: excluding a board can only
    # ever shrink what gets deleted, so the conservative reading is the correct
    # one, and it covers multi-group and shared membership for free.
    def set_root_ids
      @set_root_ids ||= board.board_groups
        .where.not(root_board_id: nil)
        .where.not(root_board_id: board.id)
        .distinct
        .pluck(:root_board_id)
    end

    def tree_ids
      @tree_ids ||= tree.map(&:id)
    end

    # Ids that vanish in this delete: the root plus its tree. An inbound tile
    # from one of these is not an outside reference — it's going away too.
    def deleted_ids
      @deleted_ids ||= tree_ids + [board.id]
    end

    def partition
      @partition ||= begin
        deletable = []
        kept = []
        tree.each do |subboard|
          reason = kept_reason(subboard)
          if reason
            kept << { id: subboard.id, name: subboard.name, reason: reason }
          else
            deletable << subboard
          end
        end
        { deletable: deletable, kept: kept }
      end
    end

    # nil when the subboard is safe to cascade-delete; otherwise the first
    # reason it must be kept. Order is deliberate — ownership problems are
    # more important to report than an incidental outside link.
    def kept_reason(subboard)
      return :predefined if subboard.predefined? || subboard.is_template?
      return :not_owned if user.nil? || subboard.user_id != user.id
      return :on_communicator if subboard.child_boards.exists?
      return :shared_with_team if subboard.team_boards.exists?
      return :referenced_outside if referenced_outside?(subboard)

      nil
    end

    # A folder tile pointing at this subboard from a board that is NOT itself
    # being deleted. reorder(nil): BoardImage's default position ordering
    # breaks the DISTINCT-ish exists? query.
    def referenced_outside?(subboard)
      BoardImage
        .where(predictive_board_id: subboard.id)
        .where.not(board_id: deleted_ids)
        .reorder(nil)
        .exists?
    end
  end
end
