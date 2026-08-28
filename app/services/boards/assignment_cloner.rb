module Boards
  # Deep-clone counterpart of Board#clone_with_images for the "put this board
  # on a communicator" paths (assign_boards, assign_accounts, MySpeak starter
  # attach). The shallow clone copied predictive_board_id verbatim, so an
  # assigned board's folder tiles kept opening the SOURCE owner's live
  # sub-boards — shared state that changed or broke when the source owner
  # edited/deleted them. This clones the linked sub-boards too (depth-capped)
  # and rewires the folder tiles to the clones, mirroring what
  # SeededSetCloner already does for builder sets.
  #
  #   root_clone = Boards::AssignmentCloner.new(
  #     board, owner: current_user, communicator: child, voice: "echo"
  #   ).call
  #
  # Root clone: is_template (unless `template_root: false`), ChildBoard on the
  # communicator, UpdateUserBoardsJob.
  # Sub-board clones: is_template (via force_template), owned by the same
  # user, NO ChildBoard rows (they surface only through folder navigation),
  # marked settings["assignment_child"] + ["assignment_root_id"] so
  # ChildBoardsController's orphan sweep can find them when the root clone is
  # removed and deleted.
  class AssignmentCloner
    class CloneError < StandardError; end

    # Root + this many levels of linked sub-boards. Deeper links are left
    # pointing at the source (exactly the pre-deep-clone behavior), not nulled.
    def self.depth_cap
      ENV.fetch("BOARD_ASSIGN_CLONE_DEPTH", 3).to_i
    end

    # `template_root:` decides what the ROOT clone is, and it is the whole
    # difference between an assignment and a board the user owns. An
    # assignment (assign_boards / assign_accounts) mints a per-communicator
    # template: invisible in the owner's board list, uncountable against
    # `board_limit`, hard-deleted when the last dashboard detaches it. The
    # MySpeak wizard's starter is not that — it is the parent's own board,
    # published on their child's public page, and one they must be able to
    # find and edit — so it clones as `template_root: false` and is gated by
    # `at_board_limit?` like any other board create.
    def initialize(source_root, owner:, communicator:, voice: nil, name: nil, template_root: true)
      @source_root   = source_root
      @owner         = owner
      @communicator  = communicator
      @voice         = voice
      @name          = name
      @template_root = template_root
    end

    # Returns the cloned root Board. Transactional: a mid-clone failure leaves
    # no orphan sub-board clones or dangling ChildBoard.
    def call
      ActiveRecord::Base.transaction do
        sources = PredictiveLinkSet.collect(@source_root, max_depth: self.class.depth_cap)

        # No communicator passed down: `clone_with_images` derives
        # `is_template` from its presence (board.rb), so handing it over would
        # force a template root and take `template_root:` away from the
        # caller. We ask for the template flag explicitly and create the
        # ChildBoard ourselves instead — same row, same columns.
        root_clone = @source_root.clone_with_images(
          @owner.id, @name || @source_root.name, @voice, nil,
          force_template: @template_root,
        )
        raise CloneError, "failed to clone board #{@source_root.id}" if root_clone.nil?

        attach_root!(root_clone)

        map = { @source_root.id => root_clone }
        sources.each do |src|
          next if src.id == @source_root.id

          clone = src.clone_with_images(@owner.id, nil, @voice, nil, force_template: true)
          raise CloneError, "failed to clone sub-board #{src.id}" if clone.nil?

          clone.settings = (clone.settings || {}).merge(
            "assignment_child" => true,
            "assignment_root_id" => root_clone.id,
          )
          clone.save!
          map[src.id] = clone
        end

        # :keep — a pointer past the depth cap stays on the source board, the
        # (known, now bounded) status quo; :null would silently break deep sets.
        PredictiveLinkSet.rewire!(map, out_of_set: :keep)
        root_clone
      end
    end

    private

    # Mirrors what Board#clone_with_images does when a communicator is passed:
    # same columns, same idempotency guard, same log-don't-raise failure mode
    # (a dashboard row is not worth losing the clone over).
    def attach_root!(root_clone)
      return if @communicator.nil?
      return if @communicator.child_boards.where(board_id: root_clone.id).exists?

      child_board = @communicator.child_boards.new(
        board: root_clone,
        created_by_id: @owner.id,
        original_board: @source_root,
      )
      return if child_board.save

      Rails.logger.error "[AssignmentCloner] Error creating ChildBoard for communicator " \
                         "#{@communicator.id} and board #{root_clone.id}: " \
                         "#{child_board.errors.full_messages.join(', ')}"
    end
  end
end
