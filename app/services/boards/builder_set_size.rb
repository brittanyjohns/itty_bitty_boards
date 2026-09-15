module Boards
  # How many Board rows one Board Builder run will persist, answerable BEFORE the
  # async job starts.
  #
  # Every board a builder set contains counts against `board_limit` (issue
  # #796), so the gate has to reserve room for the WHOLE set — half a set is
  # worse than no set, and the job has no way to stop partway and stay coherent.
  #
  # A level is sized from the REQUEST, not from the most any build at that level
  # could create. The reservation used to be `max_pages` interest pages plus the
  # whole GLP Phrases layer on every build, so an Extended set that makes 12
  # boards reserved 35 and refused a user with 34 free. The counts, verified
  # against BuildBoardSetJob#build_with_structure_planner:
  #
  #   root          — created by the controller before the job runs
  #   seed pages    — SeededSetCloner runs with `exclude_fringe: []` ("clone the
  #                   authored core set INTACT"), so the whole authored tree
  #                   comes along regardless of what the planner planned
  #   planned pages — the NON-seed prebuilt/AI pages the planner adds for these
  #                   interests (add_fringe_pages! skips :seed_set pages, which
  #                   the clone already brought); one board each
  #   favorites     — "My Favorites", created once and reused, and only ever
  #                   holding interests the request carried
  #
  # The planner runs with no user, which skips the AI-credit downgrade: fewer
  # credits can only turn an AI page into My Favorites words, so the answer
  # stays an upper bound. The Phrases layer is not reserved — GLP is admin-only,
  # and admins are exempt from the cap.
  #
  # A StarterBlueprints tree (e.g. "home", the Quick Start set) is built by
  # BuildBoardSetJob#build_legacy -> BlueprintAssembler -> BoardTreeBuilder, with
  # no seed set and no phrases layer, so it is sized from the tree itself.
  class BuilderSetSize
    ROOT_BOARDS = 1
    FAVORITES_BOARDS = 1
    PHRASES_LAYER_BOARDS = 1 + Boards::GlpTemplates::TEMPLATES.size

    # The reservation the create gate makes for this request.
    def self.for_request(build_key, interests: [], explicit_categories: {})
      key = build_key.to_s.downcase

      level = Boards::StructurePlanner::LEVELS[key]
      return level_cost(key, level, Array(interests), explicit_categories || {}) if level

      tree = Boards::StarterBlueprints.tree_for(key)
      return blueprint_worst_case(tree) if tree

      # Robust sets (core-60 / core-84) clone a whole authored tree whose size
      # isn't knowable here; keep the roomy bound for those.
      legacy_worst_case
    end

    # What a level takes with no interests — the picker's `board_cost`. A floor,
    # not a promise: interests can only add pages, so a client pre-check against
    # it never refuses a build the create gate would allow.
    def self.base_cost(build_key)
      for_request(build_key)
    end

    def self.level_cost(key, level, interests, explicit_categories)
      plan = Boards::StructurePlanner.new(
        level: key, interests: interests, explicit_categories: explicit_categories,
      ).call
      planned_pages = plan.fringe_pages.count { |page| page[:source] != :seed_set }
      favorites = interests.any? ? FAVORITES_BOARDS : 0

      ROOT_BOARDS + seed_page_count(level) + planned_pages + favorites
    end

    def self.seed_page_count(level)
      Boards::StructurePlanner::SEED_SET_PAGES.fetch(level[:core_template], []).size
    end

    # A blueprint's boards are its root, one per folder tile (at any depth —
    # counting past BoardTreeBuilder::MAX_DEPTH only over-estimates, which is the
    # safe direction), plus the "My Favorites" page
    # BlueprintAssembler#route_interests! appends for interests that don't route
    # into one of the blueprint's own folders.
    def self.blueprint_worst_case(tree)
      ROOT_BOARDS + folder_count(tree) + FAVORITES_BOARDS
    end

    def self.folder_count(node)
      Array(node[:tiles]).sum do |tile|
        tile[:children] ? 1 + folder_count(tile[:children]) : 0
      end
    end

    # The bound for a robust-set slug (or anything else) whose page count isn't
    # knowable without assembling it: the roomiest shape any level can take —
    # every page up to max_pages, the Phrases layer, and My Favorites.
    def self.legacy_worst_case
      Boards::StructurePlanner::LEVELS.values.map do |level|
        ROOT_BOARDS + seed_page_count(level) + level[:max_pages] + PHRASES_LAYER_BOARDS + FAVORITES_BOARDS
      end.max
    end
  end
end
