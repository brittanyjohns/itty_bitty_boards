module Boards
  # Publishing a Board Builder root without its set leaves a broken public
  # page: Board#viewable_by? gates each board on its own `published` flag, so
  # a visitor tapping a folder tile on a published root hits the sub-page's
  # 404. Unpublishing only the root leaks the reverse — every sub-page stays
  # reachable by its own /pb/<slug>.
  #
  # This cascades `published` across the boards owned by the root's builder
  # BoardGroup — the SAME set Boards::UsageCheck#builder_group cascades on
  # delete, so a built set publishes, unpublishes, and deletes as one unit.
  # Deliberately NOT PredictiveLinkSet: hand-linked folder tiles outside the
  # builder set are not owned by the root and are not ours to flip.
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
      group = builder_group
      return Board.none unless group

      # `where.not(published: published)` is SQL `NOT (published = X)`, which
      # evaluates to NULL (excluded) for a NULL row — a legacy member with
      # published IS NULL would silently never be counted or flipped, leaving
      # it out of sync after a confirmed cascade. IS DISTINCT FROM treats NULL
      # as a real, comparable value so those members are included too.
      group.boards.distinct
           .where(user_id: board.user_id)
           .where.not(id: board.id)
           .where("published IS DISTINCT FROM ?", published)
    end
  end
end
