module Boards
  # Deep-clone counterpart of Board#clone_with_images: clones a board TOGETHER
  # WITH the linked sub-boards its folder tiles open, and rewires those tiles to
  # the clones. The shallow clone copies predictive_board_id verbatim, so a
  # copied folder tile kept opening the SOURCE owner's live sub-board — shared
  # state that changed or broke when they edited or deleted it.
  #
  # Three callers, and `template_root:` is what separates them:
  #
  #   assign_boards / assign_accounts   template_root: true   — per-communicator
  #     assignment templates: invisible in the owner's board list, uncountable
  #     against board_limit, hard-deleted when the last dashboard detaches them.
  #
  #   MySpeak onboarding starter        template_root: false  — the parent's own
  #     board, published on their child's public page, one they must be able to
  #     find and edit.
  #
  #   POST /boards/:id/clone            template_root: false  — the same thing
  #     without a communicator: "Use this board" on the public library.
  #
  # `template_root:` governs the SUB-boards too, and that is deliberate. It used
  # to force every sub-clone to a template regardless, which made a copied SET
  # cost exactly one board slot and hid its pages from the board list entirely —
  # the owner could reach them by tapping a folder tile but never find them to
  # edit. A set the user owns is N boards and costs N slots; an assignment is
  # scaffolding and costs none.
  #
  #   cloner = Boards::SetCloner.new(board, owner: current_user, communicator: child)
  #   root   = cloner.call
  #   cloner.boards_created   # => 6
  #   cloner.tiles_flattened  # => 0
  #
  # (Was Boards::AssignmentCloner; renamed once it stopped being only about
  # assignments.)
  class SetCloner
    class CloneError < StandardError; end

    # Root + this many levels of linked sub-boards.
    def self.depth_cap
      ENV.fetch("BOARD_ASSIGN_CLONE_DEPTH", 3).to_i
    end

    # How many boards this clone actually created, and how many folder tiles it
    # turned into ordinary speaking tiles. Read after #call.
    attr_reader :boards_created, :tiles_flattened

    # max_boards:  hard cap on the size of the copied set — the caller's board
    #              slot budget, or nil for the assignment paths, which cost no
    #              slots and so have nothing to budget. Boards past the cap are
    #              not cloned and the tiles that opened them are handled by
    #              `out_of_set`.
    # out_of_set:  what to do with a folder tile whose target was NOT copied.
    #              :keep for assignments — a link past the depth cap keeps
    #              working exactly as it did before deep cloning existed.
    #              :flatten for boards the user owns — see PredictiveLinkSet.
    # prefix_sub_names: name sub-clones "<root> · <page>" so they are
    #              distinguishable in a board list they now appear in.
    def initialize(source_root, owner:, communicator: nil, voice: nil, name: nil,
                   template_root: true, max_depth: nil, max_boards: nil,
                   out_of_set: :keep, prefix_sub_names: false)
      @source_root      = source_root
      @owner            = owner
      @communicator     = communicator
      @voice            = voice
      @name             = name
      @template_root    = template_root
      @max_depth        = max_depth || self.class.depth_cap
      @max_boards       = max_boards
      @out_of_set       = out_of_set
      @prefix_sub_names = prefix_sub_names
      @boards_created   = 0
      @tiles_flattened  = 0
    end

    # Returns the cloned root Board. Transactional: a mid-clone failure leaves
    # no orphan sub-board clones or dangling ChildBoard.
    def call
      ActiveRecord::Base.transaction do
        sources = PredictiveLinkSet.collect(
          @source_root, max_depth: @max_depth, max_boards: @max_boards,
        )

        # No communicator passed down: `clone_with_images` derives
        # `is_template` from its presence (board.rb), so handing it over would
        # force a template root and take `template_root:` away from the
        # caller. We ask for the template flag explicitly and create the
        # ChildBoard ourselves instead — same row, same columns.
        root_clone = @source_root.clone_with_images(
          @owner.id, root_name, @voice, nil,
          force_template: @template_root,
        )
        raise CloneError, "failed to clone board #{@source_root.id}" if root_clone.nil?

        @boards_created = 1
        attach_root!(root_clone)

        map = { @source_root.id => root_clone }
        sources.each do |src|
          next if src.id == @source_root.id

          clone = src.clone_with_images(
            @owner.id, sub_name(src), @voice, nil, force_template: @template_root,
          )
          raise CloneError, "failed to clone sub-board #{src.id}" if clone.nil?

          clone.settings = (clone.settings || {}).merge(sub_markers(root_clone))
          clone.save!
          map[src.id] = clone
          @boards_created += 1
        end

        @tiles_flattened = PredictiveLinkSet.rewire!(map, out_of_set: @out_of_set)
        root_clone
      end
    end

    private

    def root_name
      @name || @source_root.name
    end

    # nil lets clone_with_images fall back to the source board's own name,
    # which is what every caller wanted before board sets became visible.
    def sub_name(src)
      return nil unless @prefix_sub_names

      "#{root_name} · #{src.name}"
    end

    # `assignment_root_id` is stamped on EVERY sub-clone, template or not:
    # Boards::PublishCascade finds a root's pages by it (with no is_template
    # filter), and without it publishing a MySpeak starter left every folder
    # tile 404ing. `assignment_child` marks a throwaway per-communicator page
    # and belongs only on templates — it is what lib/tasks/myspeak.rake filters
    # on, and a board the user owns and paid a slot for is not throwaway.
    def sub_markers(root_clone)
      markers = { "assignment_root_id" => root_clone.id }
      markers["assignment_child"] = true if @template_root
      markers
    end

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

      Rails.logger.error "[SetCloner] Error creating ChildBoard for communicator " \
                         "#{@communicator.id} and board #{root_clone.id}: " \
                         "#{child_board.errors.full_messages.join(', ')}"
    end
  end
end
