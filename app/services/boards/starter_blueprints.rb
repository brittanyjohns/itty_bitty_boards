# app/services/boards/starter_blueprints.rb
#
# Hardcoded starter blueprints for exercising Boards::BoardTreeBuilder end to
# end. Trees are defined by *label* (DB-portable) and a dev helper resolves each
# label -> Image#id for a given user at call time, returning a builder-ready
# blueprint of resolved image_ids.
#
# NOTE: the label -> image_id step is intentionally OUTSIDE the builder. The
# builder's input contract is a blueprint of already-resolved image_ids;
# resolution lives here. Core labels resolve create-if-missing (blank art),
# mirroring the interest path in Boards::BlueprintAssembler, so a template can
# build even when its curated symbols aren't seeded in this environment.
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
        { label: "Play", children: { name: "Play",
                                     tiles: [{ label: "ball" }, { label: "bubbles" }, { label: "music" }] } },
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
      resolved = { label: tile[:label], image_id: resolve_or_create_image(tile[:label], user).id }
      resolved[:children] = resolve(tile[:children], user) if tile[:children]
      resolved
    end

    # Resolve a core label -> Image, creating a blank-art image if none exists.
    # Mirrors Boards::BlueprintAssembler#resolve_or_create_image (the interest
    # path) so the templates self-heal: a missing core symbol — including the
    # capitalized folder labels ("Food", "Feelings", "Play"), which are folder
    # names, not seeded vocabulary — yields a blank tile instead of a 500. Art
    # can be added later. Resolution order: the user's own image, then a
    # public/admin image, else create.
    def resolve_or_create_image(label, user)
      image = user.images.find_by(label: label)
      image ||= Image.public_img.find_by(label: label, user_id: [User::DEFAULT_ADMIN_ID, nil])
      image ||= Image.create!(label: label, user_id: user.id)
      image
    end

    def home(user)
      resolve(HOME, user)
    end

    def daily_routine(user)
      resolve(DAILY_ROUTINE, user)
    end
  end
end
