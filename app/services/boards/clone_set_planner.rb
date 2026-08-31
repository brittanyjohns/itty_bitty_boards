module Boards
  # Sizes a board set BEFORE anything is copied: how many boards it contains,
  # how many of them this user has room for, and how many folder tiles will
  # therefore become ordinary speaking tiles.
  #
  # Exists so the confirm dialog and the copy itself can never disagree.
  # GET /boards/:id/clone_plan renders a plan, POST /boards/:id/clone builds a
  # fresh one and hands its budget to Boards::SetCloner, and the MySpeak
  # onboarding starter does the same. One walk, one budget rule, one answer.
  #
  #   plan = Boards::CloneSetPlanner.new(board, user: current_user).call
  #   plan.boards_to_create  # => 3
  #   plan.limited_by        # => "board_limit"
  #
  # The plan is a FORECAST, not a reservation: slots can move between the
  # preview request and the copy. The copy replans and reports what it actually
  # did, which is why the after-notice carries its own counts.
  class CloneSetPlanner
    # Root + this many levels of linked sub-boards.
    def self.depth_cap
      ENV.fetch("BOARD_CLONE_SET_DEPTH", 6).to_i
    end

    # Hard ceiling on one copy, INDEPENDENT of the slot budget. A Pro user has
    # 300 slots, and cloning 300 boards inside one request — each one enqueuing
    # a preview job — is a timeout, not a limit question. Boards past it are
    # dropped exactly like boards past the budget, but reported as
    # limited_by: "set_size" so the client offers no Upgrade button: paying
    # more would not copy them.
    def self.max_set
      ENV.fetch("BOARD_CLONE_SET_MAX_BOARDS", 50).to_i
    end

    Plan = Struct.new(
      :boards_in_set, :boards_to_create, :tiles_to_flatten,
      :remaining_slots, :board_limit, :board_count,
      :limited_by, :truncated,
      keyword_init: true,
    ) do
      # Whether the copy is the whole set. `false` is what makes the client
      # confirm with "we'll copy 3 of 6" instead of "we'll copy all 6".
      def complete?
        boards_to_create >= boards_in_set && !truncated
      end

      def as_json(*)
        to_h.transform_keys(&:to_s)
      end
    end

    def initialize(source_root, user:, max_depth: nil, max_set: nil)
      @source_root = source_root
      @user        = user
      @max_depth   = max_depth || self.class.depth_cap
      @max_set     = max_set || self.class.max_set
    end

    def call
      # Walk one past the ceiling so `truncated` can tell "exactly at the
      # ceiling" from "there was more we aren't copying".
      sources = PredictiveLinkSet.collect(
        @source_root, max_depth: @max_depth, max_boards: @max_set + 1,
      )
      truncated = sources.size > @max_set
      sources = sources.first(@max_set)

      budget = slot_budget
      keep = sources.first([budget, sources.size].min)
      keep_ids = keep.map(&:id).to_set

      Plan.new(
        boards_in_set: sources.size,
        boards_to_create: keep.size,
        tiles_to_flatten: flattenable_tile_count(keep_ids),
        remaining_slots: renderable_slots,
        board_limit: @user.board_limit,
        board_count: @user.countable_board_count,
        limited_by: limited_by(keep.size, sources.size, budget, truncated),
        truncated: truncated,
      )
    end

    private

    # Every folder tile on a board we ARE copying whose target board we are
    # NOT — including a pointer to a board that no longer exists, and one that
    # left the set at the depth cap. Each becomes a speaking tile.
    def flattenable_tile_count(keep_ids)
      return 0 if keep_ids.empty?

      BoardImage.where(board_id: keep_ids)
                .where.not(predictive_board_id: nil)
                .where.not(predictive_board_id: keep_ids)
                .count
    end

    def slot_budget
      remaining = @user.board_limit_remaining
      remaining.infinite? ? @max_set : remaining
    end

    # board_limit_remaining is Infinity for admins; the payload is JSON.
    def renderable_slots
      remaining = @user.board_limit_remaining
      remaining.infinite? ? @user.board_limit : remaining
    end

    # "board_limit" is the only value that earns an Upgrade button — it is the
    # only shortfall the user can pay to fix.
    def limited_by(created, total, budget, truncated)
      return "board_limit" if created < total && budget < total
      return "set_size" if truncated || created < total

      nil
    end
  end
end
