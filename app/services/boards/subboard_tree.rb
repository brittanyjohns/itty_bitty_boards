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

    # Every board reachable from `board` through folder tiles, minus the root
    # itself. LinkedBoardsFinder already handles link cycles and caps the walk.
    def tree
      @tree ||= LinkedBoardsFinder.new(board).call.reject { |b| b.id == board.id }
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
