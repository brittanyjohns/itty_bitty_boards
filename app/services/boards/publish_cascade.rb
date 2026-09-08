module Boards
  # Publishing a Board Builder root without its set leaves a broken public
  # page: Board#viewable_by? gates each board on its own `published` flag, so
  # a visitor tapping a folder tile on a published root hits the sub-page's
  # 404. Unpublishing only the root leaks the reverse — every sub-page stays
  # reachable by its own /pb/<slug>.
  #
  # This cascades `published` across the boards belonging to the root's tree,
  # from three sources:
  #
  #   1. the root's builder BoardGroup — the SAME set
  #      Boards::UsageCheck#builder_group cascades on delete, so a built set
  #      publishes, unpublishes, and deletes as one unit;
  #   2. Boards::SetCloner's sub-clones, which carry
  #      settings["assignment_root_id"] and have no BoardGroup at all; and
  #   3. PUBLISH ONLY — every board the root descends into through folder
  #      tiles (board_images.predictive_board_id), owned by the root's owner.
  #
  # Source 3 is deliberately ASYMMETRIC, and that is the whole point:
  #
  #   Publishing has to reach it. A hand-built board starred onto a MySpeak
  #   page is published by Boards::MySpeakPublisher, but sources 1 and 2 both
  #   read membership (a BoardGroup row, an assignment stamp) that a hand-linked
  #   page never has — so the card worked and every folder tile 404'd. The
  #   invariant is "a board reachable from a MySpeak page is published", and
  #   reachability is the tile graph, not the bookkeeping.
  #
  #   Unpublishing must NOT. A hand-linked page can be reached from more than
  #   one root, and from more than one communicator's page; its /pb/<slug> may
  #   already be printed into an IEP. Unpublishing one parent is not a decision
  #   about a page somebody else's board also opens. So unpublish keeps the
  #   old, narrower scope — sources 1 and 2 only, which ARE owned by the root.
  class PublishCascade
    # Counts in the summary are exact; name lists are sampled so a large set
    # can't blow up the 409 payload. Mirrors UsageCheck::NAME_SAMPLE_LIMIT.
    NAME_SAMPLE_LIMIT = 10

    # How many LEVELS of folder tiles the publish descent follows. Bounds
    # levels, not nodes — ReachableBoardIds already caps nodes — because it is
    # levels that multiply queries (one per level). Matches
    # Boards::QuickAddScope::MAX_DEPTH, the other reachability walk over the
    # same graph. Deliberately NOT Boards::CloneSetPlanner.depth_cap: that is a
    # tunable clone BUDGET, and turning it down to make copies cheaper must not
    # quietly stop publishing the bottom of somebody's board set.
    MAX_DEPTH = 12

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
      backfill_slugs!(ids) if published
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
      ids = member_board_ids(published)
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

    # The ways a board can belong to this root's tree. All are resolved to ids
    # and unioned so one query carries the `IS DISTINCT FROM` / ownership
    # conditions for every source.
    #
    # `descendant_ids` joins only when PUBLISHING — see the asymmetry argument
    # on the class. An unpublish sees exactly what it saw before this existed.
    def member_board_ids(published)
      ids = builder_member_ids | assignment_child_ids
      ids |= descendant_ids if published
      ids
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

    # Every board this root descends INTO through folder tiles. The third
    # membership source, and the only one that reads the tile graph rather than
    # a stored membership row — which is exactly why it is here: a page linked
    # by hand has no BoardGroup row and no assignment stamp, so nothing else
    # sees it, yet a visitor reaches it in one tap.
    #
    # Three rails, all load-bearing:
    #
    #   `skip_back_tiles` — a child page's "go back" tile points UP at the set
    #   root. Following it turns a two-page descent into the whole set plus
    #   every sibling of every ancestor.
    #
    #   `admit` — THE OWNERSHIP CONTROL, and a security control, not an
    #   optimization. `predictive_board_id` is permitted on the generic tile
    #   update path without validating the target, so a tile on my board may
    #   point at a stranger's. The walk therefore refuses to FOLLOW such a
    #   pointer rather than walking through it and filtering afterwards — the
    #   children of a board I don't own are not mine to publish either. Same
    #   reasoning, and the same once-per-level shape, as
    #   Boards::QuickAddScope#entitled_ids.
    #
    #   `max_depth` — bounds queries. A truncated walk publishes less than the
    #   whole tree, which is the safe direction to be wrong in: some folder
    #   tiles keep 404ing, none of the user's private boards go public.
    #
    # The root is dropped here and again by `member_boards_to_change`; the
    # caller saves it through the normal update path so its callbacks run.
    def descendant_ids
      Boards::ReachableBoardIds.new(
        board.id,
        skip_back_tiles: true,
        max_depth: MAX_DEPTH,
        admit: method(:owner_board_ids),
      ).ids - [board.id]
    end

    # The subset of `candidate_ids` this root's OWNER owns. Called once per
    # level by the walk, never per id.
    def owner_board_ids(candidate_ids)
      Board.where(id: candidate_ids, user_id: board.user_id).reorder(nil).pluck(:id)
    end

    # A board published by `update_all` never ran `ensure_slug`, so a member
    # that has never had a slug comes out `published: true` with no
    # /pb/<slug> — visible in the cascade summary, reachable by nobody. Loads
    # only the blank ones, which is normally none.
    #
    # Publish-only by construction: unpublishing can't create this state, and
    # `generate_unique_slug` on an already-published board would collide with
    # `freeze_published_slug` anyway.
    def backfill_slugs!(ids)
      Board.where(id: ids).where("slug IS NULL OR slug = ''").find_each do |member|
        member.generate_unique_slug
        member.save!
      rescue => e
        # One unsluggable member must not roll back a cascade that has already
        # published the rest.
        Rails.logger.error("[PublishCascade] slug backfill failed board=#{member.id}: #{e.class} - #{e.message}")
      end
    end
  end
end
