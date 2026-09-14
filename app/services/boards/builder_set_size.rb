module Boards
  # Upper bound on how many Board rows one Board Builder run will persist,
  # answerable BEFORE the async job starts.
  #
  # Every board a builder set contains counts against `board_limit` (issue
  # #796), so the gate has to reserve room for the WHOLE set — half a set is
  # worse than no set, and the job has no way to stop partway and stay coherent.
  # Deliberately an over-estimate: refusing a build that would have just fit is
  # recoverable (delete a board, or upgrade), while overrunning the cap is not.
  #
  # Every component is derived from a constant rather than hardcoded, so adding
  # a seed page or a GLP function board moves the bound automatically. The
  # counts, verified against BuildBoardSetJob#build_with_structure_planner:
  #
  #   root          — created by the controller before the job runs
  #   seed pages    — SeededSetCloner runs with `exclude_fringe: []` ("clone the
  #                   authored core set INTACT"), so the whole authored tree
  #                   comes along regardless of what the planner planned
  #   planned pages — the non-seed prebuilt/AI pages; StructurePlanner#cap_pages
  #                   caps the whole fringe list at the level's max_pages, so
  #                   max_pages bounds what is added on top of the seed set
  #   phrases layer — PhrasesPageBuilder: one "Phrases" board plus one clone per
  #                   seeded GLP function board
  #   favorites     — the "My Favorites" catch-all (created once, then reused)
  #
  # A StarterBlueprints tree (e.g. "home", the Quick Start set) is built by
  # BuildBoardSetJob#build_legacy -> BlueprintAssembler -> BoardTreeBuilder, with
  # no seed set and no phrases layer, so it is sized from the tree itself.
  class BuilderSetSize
    ROOT_BOARDS = 1
    FAVORITES_BOARDS = 1
    PHRASES_LAYER_BOARDS = 1 + Boards::GlpTemplates::TEMPLATES.size

    def self.worst_case(build_key)
      key = build_key.to_s.downcase

      level = Boards::StructurePlanner::LEVELS[key]
      return level_worst_case(level) if level

      tree = Boards::StarterBlueprints.tree_for(key)
      return blueprint_worst_case(tree) if tree

      # Robust sets (core-60 / core-84) clone a whole authored tree whose size
      # isn't knowable here; keep the roomy bound for those.
      legacy_worst_case
    end

    def self.level_worst_case(level)
      seed_pages = Boards::StructurePlanner::SEED_SET_PAGES
                     .fetch(level[:core_template], []).size

      ROOT_BOARDS + seed_pages + level[:max_pages] + PHRASES_LAYER_BOARDS + FAVORITES_BOARDS
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

    # The roomiest level we ship: the bound for a robust-set slug (or anything
    # else) whose page count isn't knowable without assembling it.
    def self.legacy_worst_case
      Boards::StructurePlanner::LEVEL_KEYS.map { |key| worst_case(key) }.max
    end
  end
end
