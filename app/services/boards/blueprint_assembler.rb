# app/services/boards/blueprint_assembler.rb
#
# The "front of the pipe" for the hybrid Board Builder wizard. Turns the wizard's
# input (a chosen starter template + a few interest words) into a *builder-ready*
# blueprint — a tree whose every tile already has a resolved `image_id` — and
# hands it to Boards::BoardTreeBuilder.
#
# Why a separate seam: BoardTreeBuilder's contract is "resolved image_ids only"
# (see #259). All label -> Image resolution, and the create-if-missing path for
# brand-new interest words, lives here so the builder stays dumb and deterministic.
#
#   assembler = Boards::BlueprintAssembler.new(
#     template: "home",
#     interests: ["dinosaurs", "trains", "grandma"],
#     user: current_user,
#   )
#   blueprint = assembler.call            # => builder-ready blueprint (or raises)
#   assembler.interests                   # => normalized list, for persisting
#
# Interest placement: each interest is routed into a matching category folder
# the chosen template already has (apple -> Food, trains -> Play) via
# Boards::InterestCategories. The curated core tiles are left untouched — an
# interest only ever *adds* a tile to an existing folder's child board, deduped
# against what's already there. Anything with no matching folder (grandma, a
# brand-new word) falls through to a single appended "My Favorites" folder, so
# nothing the user typed is ever dropped. See .claude-notes/board-builder.md.
module Boards
  class BlueprintAssembler
    FAVORITES_NAME = "My Favorites"
    MAX_INTERESTS  = 12

    class UnknownTemplate < StandardError; end

    attr_reader :interests

    def initialize(template:, user:, interests: [])
      @template_key = template.to_s
      @user         = user
      @interests    = normalize_interests(interests)
    end

    # Returns a builder-ready blueprint: the resolved template with interests
    # routed into matching category folders and any leftovers in "My Favorites".
    # Raises UnknownTemplate if the template key isn't registered.
    def call
      blueprint = StarterBlueprints.for(@template_key, @user)
      raise UnknownTemplate, "unknown template #{@template_key.inspect}" if blueprint.nil?

      route_interests!(blueprint) if @interests.any?
      blueprint
    end

    private

    # Drop each interest into the template folder its category maps to; collect
    # whatever has no home and hang it off a single "My Favorites" folder.
    def route_interests!(blueprint)
      folders  = folder_tiles_by_label(blueprint)
      unrouted = []

      @interests.each do |word|
        category = Boards::InterestCategories.category_for(word)
        folder   = category && folders[category]
        folder ? add_interest_to_folder(folder, word) : unrouted << word
      end

      blueprint[:tiles] = blueprint[:tiles] + [favorites_folder(unrouted)] if unrouted.any?
    end

    # { "Food" => <folder tile>, ... } for every top-level tile that's a folder.
    def folder_tiles_by_label(blueprint)
      blueprint[:tiles].each_with_object({}) do |tile, map|
        map[tile[:label]] = tile if tile[:children]
      end
    end

    # Append an interest tile to a folder's child board, deduping (case-
    # insensitively) against the seed tiles and any interest already routed here.
    def add_interest_to_folder(folder, word)
      existing = folder[:children][:tiles].map { |t| t[:label].to_s.downcase }
      return if existing.include?(word.downcase)

      folder[:children][:tiles] << { label: word, image_id: resolve_or_create_image(word).id }
    end

    # A folder tile (has `children`) pointing at a board built from the leftover
    # interest words. The folder tile itself needs an image (board_images.image_id
    # is NOT NULL), so we resolve/create one for the folder label too.
    def favorites_folder(words)
      {
        label:    FAVORITES_NAME,
        image_id: resolve_or_create_image(FAVORITES_NAME).id,
        children: {
          name:  FAVORITES_NAME,
          tiles: words.map { |word| { label: word, image_id: resolve_or_create_image(word).id } },
        },
      }
    end

    # Mirrors Board#find_or_create_images_from_word_list resolution order:
    # the user's own image, then a public/admin image, else create a new one.
    # A freshly-created image starts with no symbol art — acceptable for v1
    # (blank tile, art can be generated later). See the plan doc's symbol note.
    def resolve_or_create_image(label)
      word = normalize_word(label)
      image = @user.images.find_by(label: word)
      image ||= Image.public_img.find_by(label: word, user_id: [User::DEFAULT_ADMIN_ID, nil])
      image ||= Image.create!(label: word, user_id: @user.id)
      image
    end

    # Normalization lives in Boards::InterestWords (shared with the cloner
    # and the controller, which persists the list and feeds BuildBoardSetJob).
    # Casing matches find_or_create_images_from_word_list: multi-char words
    # kept as typed, lone "i" -> "I", other single chars lowercased.
    def normalize_interests(list)
      Boards::InterestWords.normalize_list(list, max: MAX_INTERESTS)
    end

    def normalize_word(string)
      Boards::InterestWords.normalize_word(string)
    end
  end
end
