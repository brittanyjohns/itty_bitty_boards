module Boards
  # Which boards may this user edit because a team put a communicator in their
  # care? (Issue #889.)
  #
  # Team role was never consulted by `Board#can_edit_for`, so a Supervisor —
  # the school SLP a parent invited precisely so she could add vocabulary —
  # could curate the communicator and attach her OWN boards, but the family's
  # board was permanently read-only to her. Her only offered action was
  # "Copy & customize", which forks a school copy away from the home copy: the
  # exact divergence the team feature exists to prevent.
  #
  # Scope is the communicators the viewer curates, never "every board the
  # owner has" — team membership must not reach a board the family never put
  # on a shared dashboard.
  #
  # REACHABILITY, not attachment. Assignment attaches the ROOT of a set and its
  # folder pages carry no `child_boards` row of their own, so an
  # attachment-only answer would let an SLP edit a Core 84 root and refuse her
  # its Food page — the same half-working shape `Boards::QuickAddScope` and
  # `Boards::PublishCascade` already had to grow a walk to avoid.
  #
  # The `admit:` filter is a SECURITY CONTROL, not an optimization: a folder
  # tile's `predictive_board_id` is unvalidated on the generic tile-update path
  # and board ids are sequential, so a tile on a curated board can point at a
  # stranger's board. The walk refuses to FOLLOW such a pointer rather than
  # filtering afterwards — same rule `QuickAddScope#entitled_ids` follows.
  #
  # Memoized per `User` (`User#team_curation`), so serializing a whole board
  # list costs the walk once rather than a query per card, and a viewer who
  # curates nothing pays exactly one cheap existence query.
  class TeamCuration
    # Bounds LEVELS, which is what multiplies queries. Same value as
    # QuickAddScope, which walks the same graph for the same reason.
    MAX_DEPTH = 12

    def self.max_boards
      ENV.fetch("TEAM_CURATION_MAX_BOARDS", 800).to_i
    end

    # `roles:` is the team roles that earn this grant. It defaults to
    # `User::CURATE_ROLES` (the EDIT question this class was built for);
    # `Boards::TeamReading` passes every role, because reading is not
    # role-gated — see `ChildAccount#viewable_by?`, which has said so all
    # along, and issue #923, where a Support invitee could see the child and
    # none of the child's boards.
    #
    # The role set is the ONLY difference between the two questions. Sharing
    # the walk keeps the `admit:` entitlement filter — a security control, not
    # an optimization — in one place rather than two.
    def initialize(user, limit: nil, roles: User::CURATE_ROLES)
      @user = user
      @limit = limit || self.class.max_boards
      @roles = roles
    end

    # Board ids this user may edit through team curation. Deliberately does
    # NOT include their own boards — ownership is answered before this is
    # consulted, and folding it in here would make an owner pay for the walk.
    def board_ids
      @board_ids ||= walk_ids
    end

    def include?(board_id)
      id_set.include?(board_id.to_i)
    end

    # The walk hit a cap, so `board_ids` is a prefix and a refusal past it is
    # "I don't know" rather than "no". Reported so a caller making a safety
    # decision can say so; nothing here fails open.
    def truncated?
      board_ids
      @truncated
    end

    # Communicators (ids) on teams where this user holds a curate role.
    # `ChildAccount` default-scopes to `archived_at: nil`, so an archived
    # communicator drops out here rather than keeping a stale grant alive.
    # Public so the specs and any future caller can assert against the same
    # list the walk seeds from.
    def curated_account_ids
      @curated_account_ids ||=
        if curate_team_ids.empty?
          []
        else
          ChildAccount.where(
            id: TeamAccount.where(team_id: curate_team_ids).select(:child_account_id),
          ).pluck(:id)
        end
    end

    private

    attr_reader :user, :limit, :roles

    def id_set
      @id_set ||= board_ids.to_set
    end

    def curate_team_ids
      @curate_team_ids ||=
        TeamUser.where(user_id: user.id, role: roles).pluck(:team_id)
    end

    # A curated communicator's dashboard. `board_id` only, never
    # `original_board_id` — that column points at the SOURCE a legacy clone was
    # made from, and the source board is on nobody's screen.
    def seed_ids
      @seed_ids ||=
        if curated_account_ids.empty?
          []
        else
          ChildBoard.where(child_account_id: curated_account_ids)
                    .reorder(nil).distinct.pluck(:board_id)
        end
    end

    def walk_ids
      @truncated = false
      return [] if seed_ids.empty?

      walk = Boards::ReachableBoardIds.new(
        seed_ids,
        skip_back_tiles: true,
        limit: limit,
        max_depth: MAX_DEPTH,
        admit: method(:entitled_ids),
      )
      ids = walk.ids
      @truncated = walk.truncated?
      ids
    end

    # Only boards belonging to the curated communicators' households may be
    # entered or expanded through. `user_id` and `owner_id` both, matching
    # `QuickAddScope#entitled_owner_ids`: a lending SLP can still own the
    # boards sitting on a claimed dashboard.
    #
    # Templates are excluded (they are not a board anyone edits in place), and
    # so are boards the viewer already owns — those are answered by ownership,
    # and admitting them here would silently widen the walk into the viewer's
    # own account.
    def entitled_ids(candidate_ids)
      return [] if candidate_ids.empty?
      return [] if household_user_ids.empty?

      Board.where(id: candidate_ids, is_template: false, user_id: household_user_ids)
           .where.not(user_id: user.id)
           .reorder(nil).pluck(:id)
    end

    def household_user_ids
      @household_user_ids ||=
        if curated_account_ids.empty?
          []
        else
          (ChildAccount.where(id: curated_account_ids)
                       .pluck(:user_id, :owner_id).flatten.compact.uniq - [user.id])
        end
    end
  end
end
