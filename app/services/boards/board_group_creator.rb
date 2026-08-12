module Boards
  # Creates (or reuses) a BoardGroup for a board so its "set map" becomes
  # available, even when the board was never built via the Board Builder
  # wizard and so never got a builder: true group automatically.
  class BoardGroupCreator
    class LimitReached < StandardError; end
    # BoardGroup#add_board rescues RecordInvalid/StandardError internally and
    # returns nil rather than raising, so the ActiveRecord::Base.transaction
    # below can't roll back on a failed member add on its own — we have to
    # notice the nil and raise ourselves, or a real failure would silently
    # ship a partially-populated group instead of surfacing.
    class MembershipAddFailed < StandardError; end

    def initialize(board:, user:)
      @board = board
      @user = user
      @created = false
    end

    # The group's owner is always the board's real owner (see #owner), never
    # the acting `user` — `user` only matters for authorization, handled by
    # the controller before this is ever called.
    def call
      board.with_lock do
        existing = board.eligible_board_group(owner)
        if existing
          resync_membership!(existing)
          @group = existing
        else
          raise LimitReached if owner.at_board_group_limit?
          @group = create_group!
          @created = true
        end
      end
      @group
    end

    # Whether the most recent #call created a brand new group (true) or
    # reused (and possibly re-synced) an existing eligible group (false).
    # Lets callers distinguish 201 vs 200 without a second, redundant
    # eligible_board_group query.
    def created?
      @created
    end

    private

    attr_reader :board, :user

    # The board's actual owner. An admin acting on someone else's board must
    # never have the resulting group land in the admin's own account, be
    # checked against the admin's own plan limit, or inflate the real owner's
    # count incorrectly — the group always belongs to, and is limited by,
    # whoever actually owns the board.
    def owner
      board.user
    end

    def create_group!
      members = Boards::LinkedBoardsFinder.new(board).call
      group = nil
      ActiveRecord::Base.transaction do
        group = BoardGroup.create!(user: owner, name: board.name, builder: false, root_board_id: board.id)
        members.each { |member| add_board!(group, member) }
        # BoardGroup#set_root_board (a before_create callback) derives
        # root_board_id from boards.first at creation time, when the group
        # has no members yet — it always clobbers the value above back to
        # nil. Re-assert it now that the group is populated; update! (not
        # update_column) so out-of-band validations still run.
        group.update!(root_board_id: board.id) unless group.root_board_id == board.id
      end
      # #add_board's own `boards.include?(member)` guard memoizes the
      # (initially empty) :boards association before any members are
      # attached; reload so the caller sees every board just added rather
      # than that stale, empty cache.
      group.reload
      # Outside the transaction: a thumbnail is cosmetic, so it seeds after the
      # group is safely committed rather than being able to roll it back.
      group.seed_display_images!
      group
    end

    # The map's membership must not silently freeze the moment a group is
    # created: re-run the same BFS and add any newly-reachable board that
    # isn't already a member. Never removes members — a board someone
    # deliberately kept in the set via the manual add/remove UI (even if no
    # longer folder-linked) must not be dropped as a side effect of this
    # endpoint. Makes re-calling create_board_group both idempotent and
    # additive: new folder links show up on the map on the next call.
    def resync_membership!(group)
      discovered = Boards::LinkedBoardsFinder.new(board).call
      current_ids = group.board_group_boards.pluck(:board_id)
      newly_reachable = discovered.reject { |member| current_ids.include?(member.id) }
      return if newly_reachable.empty?

      newly_reachable.each { |member| add_board!(group, member) }
      group.reload
      group.seed_display_images!
    end

    def add_board!(group, member)
      result = group.add_board(member)
      raise MembershipAddFailed, "failed to add board #{member.id} to group #{group.id}" if result.nil?
      result
    end
  end
end
