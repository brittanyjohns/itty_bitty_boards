module Boards
  # Deep-clone counterpart of Board#clone_with_images: clones a board TOGETHER
  # WITH the linked sub-boards its folder tiles open, and rewires those tiles to
  # the clones. The shallow clone copies predictive_board_id verbatim, so a
  # copied folder tile kept opening the SOURCE owner's live sub-board — shared
  # state that changed or broke when they edited or deleted it.
  #
  # Every board this creates is a REAL board the owner can see, edit and delete,
  # and a copied set costs one slot per board. Two callers:
  #
  #   MySpeak onboarding starter — the parent's own board, published on their
  #     child's public page, one they must be able to find and edit.
  #
  #   POST /boards/:id/clone     — the same thing without a communicator:
  #     "Use this board" on the public library.
  #
  # It used to have a third, `assign_boards` / `assign_accounts`, which passed
  # `template_root: true` to mint an invisible per-communicator copy — a board
  # excluded from its owner's board list and from the board-limit count, that no
  # edit to the source could ever reach. Assignment ATTACHES a board now, so
  # that caller and the flag are both gone. Do not reintroduce a mode that hides
  # a board from the person who owns it.
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
    #              slot budget. Boards past the cap are not cloned and the tiles
    #              that opened them are handled by `out_of_set`.
    # out_of_set:  what to do with a folder tile whose target was NOT copied.
    #              :flatten for boards the user owns, :null for builder sets —
    #              see PredictiveLinkSet.
    # prefix_sub_names: name sub-clones "<root> · <page>" so they are
    #              distinguishable in the board list they appear in.
    def initialize(source_root, owner:, communicator: nil, voice: nil, name: nil,
                   max_depth: nil, max_boards: nil,
                   out_of_set: :flatten, prefix_sub_names: false)
      @source_root      = source_root
      @owner            = owner
      @communicator     = communicator
      @voice            = voice
      @name             = name
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

        root_clone = @source_root.clone_with_images(@owner.id, root_name, @voice)
        raise CloneError, "failed to clone board #{@source_root.id}" if root_clone.nil?

        @boards_created = 1
        attach_root!(root_clone)

        map = { @source_root.id => root_clone }
        sources.each do |src|
          next if src.id == @source_root.id

          clone = src.clone_with_images(@owner.id, sub_name(src), @voice)
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

    # `assignment_root_id` is stamped on EVERY sub-clone:
    # Boards::PublishCascade finds a root's pages by it, and without it
    # publishing a MySpeak starter left every folder tile 404ing. (The companion
    # `assignment_child` marker is not written any more — it flagged a throwaway
    # per-communicator page, and nothing mints those since assignment stopped
    # cloning. Legacy rows still carry it; lib/tasks/myspeak.rake reads it.)
    def sub_markers(root_clone)
      { "assignment_root_id" => root_clone.id }
    end

    # Idempotency guard plus a log-don't-raise failure mode: a dashboard row is
    # not worth losing the clone over.
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
