module Boards
  # Publishing a Board Builder root without its set leaves a broken public
  # page: Board#viewable_by? gates each board on its own `published` flag, so
  # a visitor tapping a folder tile on a published root hits the sub-page's
  # 404. Unpublishing only the root leaks the reverse — every sub-page stays
  # reachable by its own /pb/<slug>.
  #
  # This cascades `published` across the boards belonging to the root's tree,
  # from two sources:
  #
  #   1. the root's builder BoardGroup — the SAME set
  #      Boards::UsageCheck#builder_group cascades on delete, so a built set
  #      publishes, unpublishes, and deletes as one unit; and
  #   2. Boards::SetCloner's sub-clones, which carry
  #      settings["assignment_root_id"] and have no BoardGroup at all.
  #
  # Deliberately NOT PredictiveLinkSet: hand-linked folder tiles outside the
  # root's own tree are not owned by the root and are not ours to flip.
  class PublishCascade
    # Counts in the summary are exact; name lists are sampled so a large set
    # can't blow up the 409 payload. Mirrors UsageCheck::NAME_SAMPLE_LIMIT.
    NAME_SAMPLE_LIMIT = 10

    def initialize(board)
      @board = board
    end

    # Only boards that would actually change count, so re-saving an
    # already-synced set never prompts the user.
    def needed?(published:)
      member_boards_to_change(published).exists?
    end

    def summary(published:)
      group = builder_group
      scope = member_boards_to_change(published)

      {
        action: published ? "publish" : "unpublish",
        board_group: group ? { id: group.id, name: group.name } : nil,
        affected: {
          count: scope.count,
          names: scope.limit(NAME_SAMPLE_LIMIT).pluck(:name),
        },
      }
    end

    # Members frozen by a marketplace listing that this cascade would unpublish.
    #
    # #apply! writes with update_all, which skips callbacks — so Board's own
    # marketplace guard never fires for a member and an unpublish would silently
    # 404 the QR on a printed page. The caller must check this before applying.
    # Only unpublishing is checked: publishing a board can't break printed paper.
    def blocked_board_ids(published:)
      return Set.new if published

      MarketplaceProtection.protected_board_ids(member_boards_to_change(published).pluck(:id))
    end

    # Flips the members only — the root is saved by the caller through the
    # normal update path. update_all skips callbacks on purpose: a built set
    # can be dozens of boards and only one boolean column changes. It also
    # skips timestamps, so updated_at is set explicitly.
    def apply!(published:)
      ids = member_boards_to_change(published).pluck(:id)
      return 0 if ids.empty?

      Board.where(id: ids).update_all(published: published, updated_at: Time.current)
      ids.size
    end

    # The builder BoardGroup owning this root's built tree, or nil when this
    # board isn't a Board Builder root.
    def builder_group
      return @builder_group if defined?(@builder_group)
      @builder_group = board.builder_board_group
    end

    private

    attr_reader :board

    # Member boards whose published flag differs from the target. Excludes the
    # root itself — it's a member of its own group, but the caller saves it.
    #
    # Scoped to the root's owner. `Board#builder_board_group` falls back to
    # `board_groups.where(builder: true).first` with no ownership filter, and
    # `add_to_groups` lets any board be added to any group id without an
    # ownership check (a known pre-existing hole, documented on
    # Board#eligible_board_group). That was contained while `published` was
    # admin-only, but #633 opened publishing to owners — without this filter a
    # user could flip `published` on someone else's board just by getting it
    # into a group they control. An admin editing another user's set is
    # unaffected: the scope follows the root board's owner, not the requester.
    def member_boards_to_change(published)
      ids = member_board_ids
      return Board.none if ids.empty?

      # `where.not(published: published)` is SQL `NOT (published = X)`, which
      # evaluates to NULL (excluded) for a NULL row — a legacy member with
      # published IS NULL would silently never be counted or flipped, leaving
      # it out of sync after a confirmed cascade. IS DISTINCT FROM treats NULL
      # as a real, comparable value so those members are included too.
      Board.where(id: ids)
           .where(user_id: board.user_id)
           .where.not(id: board.id)
           .where("published IS DISTINCT FROM ?", published)
    end

    # The two ways a board can belong to this root's tree. Both are resolved to
    # ids and unioned so one query carries the `IS DISTINCT FROM` / ownership
    # conditions for both.
    def member_board_ids
      builder_member_ids | assignment_child_ids
    end

    def builder_member_ids
      group = builder_group
      return [] unless group

      group.boards.distinct.pluck(:id)
    end

    # Boards::SetCloner deep-clones a starter's sub-boards and stamps
    # each with settings["assignment_root_id"] = <root clone id>. It creates NO
    # BoardGroup, so a clone tree is invisible to `builder_group` — publishing
    # such a root left every folder tile 404ing, the exact failure this class
    # exists to prevent.
    #
    # Unlike a hand-linked folder tile (deliberately out of scope: not the
    # root's to flip), these pages were minted FOR this root and belong to the
    # same owner, so they publish and unpublish as one unit with it. The
    # ownership filter in #member_boards_to_change still applies.
    def assignment_child_ids
      Board.where(user_id: board.user_id)
           .where("settings->>'assignment_root_id' = ?", board.id.to_s)
           .pluck(:id)
    end
  end
end
