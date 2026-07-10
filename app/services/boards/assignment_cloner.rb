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
  # Root clone: unchanged contract — is_template, ChildBoard on the
  # communicator (created inside clone_with_images), UpdateUserBoardsJob.
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

    def initialize(source_root, owner:, communicator:, voice: nil, name: nil)
      @source_root  = source_root
      @owner        = owner
      @communicator = communicator
      @voice        = voice
      @name         = name
    end

    # Returns the cloned root Board. Transactional: a mid-clone failure leaves
    # no orphan sub-board clones or dangling ChildBoard.
    def call
      ActiveRecord::Base.transaction do
        sources = PredictiveLinkSet.collect(@source_root, max_depth: self.class.depth_cap)

        root_clone = @source_root.clone_with_images(@owner.id, @name || @source_root.name, @voice, @communicator)
        raise CloneError, "failed to clone board #{@source_root.id}" if root_clone.nil?

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
  end
end
