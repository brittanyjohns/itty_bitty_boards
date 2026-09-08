module Boards
  # Which boards may this actor quick-add a word to, and which of them does
  # somebody else also see?
  #
  # ONE object answers both questions, and both the picker
  # (API::Account::QuickAddTargetsController, Api::BoardsController#list) and
  # the write gate (check_communicator_board_access!) instantiate it. That is
  # the point: the read set and the write set are the same code path, so a
  # board the picker offers cannot 403, and widening one cannot fail to widen
  # the other. Same reasoning as Permissions::CommunicatorLimits.slots_for.
  #
  # Two questions it deliberately keeps separate:
  #
  #   * MEMBERSHIP (`include?`) — enforced. A board reached only through a
  #     folder tile pointing into somebody else's account is refused.
  #   * SHARING (`shared?`) — advisory. Nobody is blocked for it; it drives a
  #     badge and a client-side confirm.
  #
  # Assignment ATTACHES a board rather than copying it, so one board is on N
  # dashboards and a tile added here reaches all of them. But assignment
  # attaches the ROOT of a set — its folder pages have no child_boards row of
  # their own — so both answers have to follow reachability, not attachment,
  # or the pages of a shared set read as private while the sibling sees every
  # word added to them.
  class QuickAddScope
    # Bounds LEVELS, which is what multiplies queries (one per level).
    MAX_DEPTH = 12

    EMPTY = Set.new.freeze

    # Read at call time, not frozen into a constant, so it retunes from
    # Hatchbox without a deploy.
    def self.max_boards
      ENV.fetch("QUICK_ADD_MAX_BOARDS", 800).to_i
    end

    # context: ChildAccount (communicator token) or User (user token).
    # seed_ids: pass the caller's already-loaded ids so they aren't re-queried.
    # acting_communicator: for a User context, "shared beyond THIS kid" rather
    #   than "shared at all". Ignored for a ChildAccount context, which is its
    #   own acting communicator.
    def initialize(context, seed_ids: nil, acting_communicator: nil, limit: nil)
      @context = context
      @explicit_seed_ids = seed_ids&.map(&:to_i)&.uniq
      @acting_communicator = context.is_a?(ChildAccount) ? context : acting_communicator
      @limit = limit || self.class.max_boards
    end

    # The pickable set, BFS order, seeds first.
    def board_ids
      walk.ids
    end

    # The walk hit a cap, so board_ids is a prefix. The picker reports it and
    # the gate refuses what fell off the end — but both read the SAME prefix,
    # so they still agree. Never an error: usage must never break.
    def truncated?
      walk.truncated?
    end

    def include?(board_id)
      id_set.include?(board_id.to_i)
    end

    # Does anyone other than the acting communicator see this board? A bare
    # boolean by design: Board#in_use_by already NAMES the communicators a
    # viewer owns, and a count here would be those same names re-counted —
    # two fields that must agree eventually don't. What this adds is the case
    # in_use_by deliberately hides: a stranger's dashboard.
    def shared?(board_id)
      audience_for(board_id).any?
    end

    # The seed board(s) this one descends from — a dashboard root, for grouping
    # pages under it in the picker.
    def root_ids_for(board_id)
      walk.origins_for(board_id.to_i).to_a
    end

    # Hydrated, with BOTH cover attachments preloaded: Board#display_image_url
    # consults preset_display_image and preview_image, and #preview_image_url
    # consults preview_image, so a missing preload is an N+1 per card that no
    # test notices until production.
    def boards
      @boards ||= Board.where(id: board_ids)
                       .with_attached_preview_image
                       .with_attached_preset_display_image
                       .to_a
    end

    private

    attr_reader :context, :explicit_seed_ids, :acting_communicator, :limit

    def walk
      @walk ||= Boards::ReachableBoardIds.new(
        seed_ids,
        skip_back_tiles: true,
        limit: limit,
        max_depth: MAX_DEPTH,
        admit: method(:entitled_ids),
        track_origins: true,
      ).tap(&:ids)
    end

    def id_set
      @id_set ||= board_ids.to_set
    end

    def seed_ids
      @seed_ids ||= explicit_seed_ids || derived_seed_ids
    end

    # A communicator's seeds are their dashboard. `board_id` only, never
    # `original_board_id` — that column points at the SOURCE a legacy clone was
    # made from, and the source board is on nobody's screen. Board#in_use_by
    # unions both and so can name one more communicator than this does; that
    # divergence is deliberate, don't "fix" either side to match.
    #
    # A user's seeds are their own boards. Passing them all (rather than only
    # the attached ones) is what lets a page inherit sharing from whichever of
    # the user's boards reaches it.
    def derived_seed_ids
      case context
      when ChildAccount
        ChildBoard.where(child_account_id: context.id).reorder(nil).distinct.pluck(:board_id)
      when User
        context.boards.reorder(nil).pluck(:id)
      else
        []
      end
    end

    # THE SECURITY CONTROL, not an optimization. A folder tile's target is
    # unvalidated on the generic tile-update path, and board ids are
    # sequential — so a tile on a board of mine can point at a stranger's
    # board. Attachment-based access made that inert; reachability does not.
    # The walk therefore refuses to FOLLOW a pointer it has no right to,
    # rather than trusting the pointer. Called once per level.
    #
    # Public/predefined library boards are deliberately absent: they are
    # admin-owned and assignment attaches the real row, so a tile added there
    # lands on the board every account sees. The owner-or-admin gate already
    # refuses the parent; this makes the communicator match the adult.
    def entitled_ids(candidate_ids)
      return [] if candidate_ids.empty?

      case context
      when ChildAccount
        Board.where(id: candidate_ids, is_template: false)
             .where("boards.user_id IN (?) OR boards.id IN (?)",
                    entitled_owner_ids,
                    team_board_ids(candidate_ids))
             .reorder(nil).pluck(:id)
      when User
        return candidate_ids if context.admin?

        Board.where(id: candidate_ids, user_id: context.id, is_template: false)
             .reorder(nil).pluck(:id)
      else
        []
      end
    end

    # The family, plus a lending SLP who still owns the boards on this
    # dashboard.
    def entitled_owner_ids
      @entitled_owner_ids ||= [context.user_id, context.owner_id].compact.uniq.presence || [-1]
    end

    # Mirrors Boards::AssignableSource#team_scope — the same allowlist that
    # decided these boards could reach the dashboard in the first place.
    def team_board_ids(candidate_ids)
      TeamBoard.where(board_id: candidate_ids)
               .where(team_id: TeamAccount.where(child_account_id: context.id).select(:team_id))
               .reorder(nil).pluck(:board_id).presence || [-1]
    end

    # A board's audience is every communicator it reaches, minus whoever is
    # asking. A page inherits from the roots that reach it (track_origins),
    # which is what makes "shared" true for every page of a shared set.
    def audience_for(board_id)
      id = board_id.to_i
      sources = walk.origins_for(id).dup
      sources << id
      sources.reduce(Set.new) { |acc, source| acc | audience_map.fetch(source, EMPTY) } - acting_account_ids
    end

    def acting_account_ids
      @acting_account_ids ||= [acting_communicator&.id].compact.to_set
    end

    # ONE query for the whole set. JOIN child_accounts rather than plucking
    # child_account_id: ChildAccount default-scopes to archived_at: nil while
    # ChildBoard does not, and original_child_boards is dependent: :nullify so
    # orphan rows exist. Without the join an ARCHIVED sibling would mark a
    # board shared forever, and the badge would never come off.
    def audience_rows
      return @audience_rows if defined?(@audience_rows)

      @audience_rows =
        if board_ids.empty?
          []
        else
          ChildBoard.joins(:child_account)
                    .where(board_id: board_ids)
                    .where(child_accounts: { archived_at: nil })
                    .reorder(nil)
                    .pluck(:board_id, :child_account_id)
        end
    end

    def audience_map
      @audience_map ||= audience_rows.each_with_object({}) do |(board_id, account_id), acc|
        (acc[board_id] ||= Set.new) << account_id
      end
    end
  end
end
