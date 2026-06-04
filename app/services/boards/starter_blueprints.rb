# app/services/boards/starter_blueprints.rb
#
# Hardcoded starter blueprints for exercising Boards::BoardTreeBuilder end to
# end. Trees are defined by *label* (DB-portable) and a dev helper resolves each
# label -> Image#id for a given user at call time, returning a builder-ready
# blueprint of resolved image_ids.
#
# NOTE: the label -> image_id step is intentionally OUTSIDE the builder. The
# builder's input contract is a blueprint of already-resolved image_ids;
# real label->image_id resolution (against interests, AI, etc.) is a separate
# seam not built here.
#
# Console exercise:
#   Boards::BoardTreeBuilder.new(
#     Boards::StarterBlueprints.home(user), communicator: child
#   ).call
module Boards
  module StarterBlueprints
    HOME = {
      name: "Home",
      tiles: [
        { label: "I" }, { label: "want" }, { label: "more" }, { label: "help" },
        { label: "yes" }, { label: "no" },
        { label: "Food", children: { name: "Food",
                                      tiles: [{ label: "apple" }, { label: "water" }, { label: "snack" }] } },
        { label: "Feelings", children: { name: "Feelings",
                                         tiles: [{ label: "happy" }, { label: "sad" }, { label: "tired" }] } },
      ],
    }.freeze

    DAILY_ROUTINE = {
      name: "My Day",
      tiles: [
        { label: "morning" }, { label: "school" }, { label: "play" }, { label: "bed" },
        { label: "Bathroom", children: { name: "Bathroom",
                                         tiles: [{ label: "toilet" }, { label: "wash" }, { label: "all done" }] } },
      ],
    }.freeze

    # Registry keyed by the stable string the wizard/API sends. Add a tree here
    # and it's instantly selectable in the picker (via #catalog) and buildable
    # (via #for) — no other wiring.
    TEMPLATES = {
      "home" => HOME,
      "daily_routine" => DAILY_ROUTINE,
    }.freeze

    module_function

    # Stable keys the API/wizard can request.
    def template_keys
      TEMPLATES.keys
    end

    # Raw (unresolved, label-only) tree for a key, or nil if unknown.
    def tree_for(key)
      TEMPLATES[key.to_s]
    end

    # Resolve a template key -> builder-ready blueprint for `user`.
    # Returns nil for an unknown key (caller decides how to surface that).
    def for(key, user)
      tree = tree_for(key)
      tree && resolve(tree, user)
    end

    # Label-only catalog for the picker UI: no Image resolution, so it's cheap
    # and safe to serve even before symbols are seeded. Each entry exposes the
    # core tile labels so the frontend can render a preview grid.
    def catalog
      TEMPLATES.map do |key, tree|
        {
          key: key,
          name: tree[:name],
          tiles: Array(tree[:tiles]).map { |t| t[:label] },
        }
      end
    end

    # Resolve a label-based tree into a builder-ready blueprint for `user`.
    def resolve(tree, user)
      {
        name: tree[:name],
        tiles: Array(tree[:tiles]).map { |tile| resolve_tile(tile, user) },
      }
    end

    def resolve_tile(tile, user)
      image = Image.where(label: tile[:label]).where(user_id: [nil, user.id, User::DEFAULT_ADMIN_ID], is_private: [nil, false]).first
      raise "Boards::StarterBlueprints: no Image for label #{tile[:label].inspect}" unless image

      resolved = { label: tile[:label], image_id: image.id }
      resolved[:children] = resolve(tile[:children], user) if tile[:children]
      resolved
    end

    def home(user)
      resolve(HOME, user)
    end

    def daily_routine(user)
      resolve(DAILY_ROUTINE, user)
    end
  end
end
