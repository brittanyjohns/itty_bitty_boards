module Boards
  # Replaces a LEGACY per-communicator assignment clone with the board it was
  # copied from.
  #
  # Assignment used to deep-clone a board into an `is_template: true` copy that
  # was invisible in its owner's board list and could never receive an edit made
  # to the source. Assignment now attaches the board itself, so those clones are
  # the last of the confusion: re-point the dashboard tile at the source and
  # delete the clone tree.
  #
  #   result = Boards::AssignmentConsolidator.new(child_board).call
  #   result.status  # => :consolidated | :skipped
  #   result.reason  # => :edited | :source_gone | :source_not_visible | ...
  #
  # This is unrecoverable — `boards` has no soft delete — so every skip reason
  # below fails CLOSED. A clone we cannot prove is untouched keeps working
  # exactly as it does today.
  class AssignmentConsolidator
    Result = Struct.new(:status, :reason, :boards_destroyed, keyword_init: true)

    # Root plus this many levels, matching what SetCloner copied.
    def self.depth_cap
      Boards::SetCloner.depth_cap
    end

    # Root plus the sub-boards its folder tiles open, in the same BFS order the
    # clone was produced in — so pages correspond position for position.
    def self.tree(root)
      Boards::PredictiveLinkSet.collect(root, max_depth: depth_cap)
    end

    def initialize(child_board, dry_run: true)
      @child_board = child_board
      @dry_run = dry_run
    end

    def call
      clone_root = @child_board.board
      return skip(:not_a_legacy_clone) if clone_root.nil? || !clone_root.is_template?

      source = Board.find_by(id: @child_board.original_board_id)
      return skip(:source_gone) if source.nil?
      return skip(:source_is_clone) if source.id == clone_root.id
      return skip(:source_not_visible) unless source_visible?(source)

      clone_tree = self.class.tree(clone_root)
      source_tree = self.class.tree(source)
      return skip(:marketplace_protected) if marketplace_protected?(clone_tree)
      return skip(:edited) unless trees_match?(clone_tree, source_tree)

      return Result.new(status: :consolidated, reason: :dry_run, boards_destroyed: clone_tree.size) if @dry_run

      apply!(clone_root, source)
    end

    private

    def skip(reason)
      Result.new(status: :skipped, reason: reason, boards_destroyed: 0)
    end

    def apply!(clone_root, source)
      favorite = @child_board.favorite?

      ActiveRecord::Base.transaction do
        # The communicator may already hold the source directly — assigned again
        # after the attach path shipped. The unique index on
        # (board_id, child_account_id) would refuse the re-point, and the tile
        # already works, so drop the redundant join instead.
        if ChildBoard.where(child_account_id: @child_board.child_account_id, board_id: source.id)
                     .where.not(id: @child_board.id).exists?
          @child_board.destroy!
        else
          @child_board.update!(board: source, original_board_id: nil)
        end
      end

      # A favorited tile is a card on the communicator's public MySpeak page,
      # and the page gates each card on Board#viewable_by? — so re-pointing at
      # an unpublished source would leave a card that 404s on tap. The favorite
      # value did not CHANGE, so ChildBoard's own hook does not fire and this
      # has to be asked for. Publishing is one-way and safe; MySpeakPublisher
      # refuses a board the page owner does not own, which is the right answer
      # for an admin library board (already published) and a teammate's board
      # (not ours to publish).
      Boards::MySpeakPublisher.new(@child_board.reload).call if favorite && @child_board.persisted?

      destroyed = Boards::AssignmentTemplateSweep.new(clone_root, actor_id: clone_root.user_id).call
      source.recalculate_in_use!

      Result.new(status: :consolidated, reason: nil, boards_destroyed: destroyed)
    end

    # The dashboard has to keep working after the swap, so the source must be
    # something this communicator's owner may hold: their own board, the public
    # library, or a board on one of the communicator's teams. Same allowlist the
    # assign endpoints use.
    def source_visible?(source)
      owner = @child_board.child_account&.user
      return false if owner.nil?

      !Boards::AssignableSource.new(@child_board.child_account, actor: owner).resolve(source.id).nil?
    end


    def marketplace_protected?(boards)
      Boards::MarketplaceProtection.protected_board_ids(boards.map(&:id)).any?
    end

    # Both trees are walked breadth-first by the same collector that produced
    # the clone in the first place, so pages correspond position for position.
    # Any divergence at all — a page added, a page removed, a tile relabelled,
    # a picture swapped, a colour changed, a tile hidden or moved — reads as
    # "edited" and skips.
    def trees_match?(clone_tree, source_tree)
      return false unless clone_tree.size == source_tree.size

      clone_tree.zip(source_tree).all? do |clone_board, source_board|
        clone_board.name == source_board.name &&
          fingerprint(clone_board) == fingerprint(source_board)
      end
    end

    # Deliberately excludes what a clone is SUPPOSED to differ on: `voice` and
    # `audio_url` (the per-communicator voice, which now resolves at read time),
    # `image_id` (re-resolved to the cloning user's own library row by label),
    # and the VALUE of `predictive_board_id` (rewired to the sub-clones — only
    # whether the tile is a folder is comparable).
    def fingerprint(board)
      board.board_images.map { |bi| self.class.tile_fields(bi).values }.sort_by(&:to_s)
    end

    # Comparable fields for one tile, keyed so a diagnostic can say WHICH one
    # diverged (see rake board_assignments:diff_report).
    #
    # Three of these are compared RESOLVED rather than literally, because
    # `BoardImage#set_defaults` fills them in on the clone when the source left
    # them blank — so a literal compare reports a divergence the user never
    # made. Comparing "what the source would seed" against "what the clone
    # holds" is the honest question. `display_image_url` keeps its three-state
    # rule: nil falls through to the library art, `""` is the "no picture"
    # marker and must not.
    def self.tile_fields(bi)
      {
        label: bi.label,
        display_label: bi.display_label.presence || bi.image&.display_label,
        display_image_url: bi.display_image_url.nil? ? bi.image&.src_url : bi.display_image_url,
        bg_color: bi.bg_color,
        font_size: bi.font_size || bi.image&.font_size,
        hidden: bi.hidden,
        layout: bi.layout,
        position: bi.position,
        folder: bi.predictive_board_id.present?,
        # Mirrors what the clone path actually wrote, rather than
        # reimplementing it: `doc_id` is nested under `text_image`, and
        # stripping a top-level key of that name (which never exists) made every
        # text tile read as edited.
        data: bi.cloned_tile_data,
      }
    end
  end
end
