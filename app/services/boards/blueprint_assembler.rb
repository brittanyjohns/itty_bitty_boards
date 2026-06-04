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
# Interest placement (v1 decision): all interests land in ONE "My Favorites"
# folder hanging off the root, leaving the curated core untouched.
# FUTURE: route interests into matching category boards (trains -> Play,
# apple -> Food) via a word->category map. Deferred on purpose — see
# drafts/board-builder-wizard-step3-plan.md.
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

    # Returns a builder-ready blueprint: { name:, tiles: [ ...image_ids..., favorites? ] }.
    # Raises UnknownTemplate if the template key isn't registered.
    def call
      blueprint = StarterBlueprints.for(@template_key, @user)
      raise UnknownTemplate, "unknown template #{@template_key.inspect}" if blueprint.nil?

      blueprint[:tiles] = blueprint[:tiles] + [favorites_folder] if @interests.any?
      blueprint
    end

    private

    # A folder tile (has `children`) pointing at a board built from the interest
    # words. The folder tile itself needs an image (board_images.image_id is NOT
    # NULL), so we resolve/create one for the folder label too.
    def favorites_folder
      {
        label:    FAVORITES_NAME,
        image_id: resolve_or_create_image(FAVORITES_NAME).id,
        children: {
          name:  FAVORITES_NAME,
          tiles: @interests.map { |word| { label: word, image_id: resolve_or_create_image(word).id } },
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

    def normalize_interests(list)
      Array(list).map { |s| normalize_word(s) }.reject(&:blank?).uniq.first(MAX_INTERESTS)
    end

    # Match the casing convention used elsewhere (find_or_create_images_from_word_list):
    # multi-char words kept as typed, lone "i" -> "I", other single chars lowercased.
    def normalize_word(string)
      word = string.to_s.strip
      return "" if word.blank?
      return "I" if word.casecmp("i").zero?

      word.length > 1 ? word : word.downcase
    end
  end
end
