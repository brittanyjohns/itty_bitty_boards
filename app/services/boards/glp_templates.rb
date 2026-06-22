# app/services/boards/glp_templates.rb
#
# Gestalt Language Processing (GLP) board templates. Six predefined,
# admin-owned template boards of WHOLE-PHRASE tiles — one per communicative
# function — for communicators who are gestalt language processors (NLA).
#
# Unlike the starter blueprints (label-only trees) and robust sets (OBF-seeded
# vocabulary), these are plain predefined boards identified by
# `category: "glp"` + `is_template: true`. They surface in the Board Builder
# `templates` response and the Script Collector frontend; the catalog +
# recommendation read them straight from the DB.
#
# Seeding (idempotent) lives in `.seed!`, driven by `glp_templates:seed`. The
# TEMPLATES table below is the single source of truth for both seeding and the
# stage-aware recommendation, so the two never drift.
module Boards
  module GlpTemplates
    CATEGORY = "glp".freeze
    BOARD_TYPE = "glp_template".freeze
    TILE_PART_OF_SPEECH = "phrase".freeze

    # Each entry: a board slug + display name, the communicative function it
    # serves, the NLA stage range (Range) it best supports, and its whole-phrase
    # tiles. Order matters: `recommended_for` picks the FIRST entry whose stage
    # range covers the communicator's stage.
    TEMPLATES = [
      {
        slug: "glp-greetings-social",
        name: "Greetings & Social",
        function: "greetings",
        stages: (1..2),
        description: "Whole-phrase greetings and social scripts for gestalt language processors.",
        tiles: ["hi there!", "see you later", "how are you?", "I love that!", "nice to see you", "good morning"],
      },
      {
        slug: "glp-requests-wants",
        name: "Requests & Wants",
        function: "requests",
        stages: (1..2),
        description: "Whole-phrase requests and wants for gestalt language processors.",
        tiles: ["I want more", "can I have that?", "let's go!", "help me please", "I need a break", "give me that"],
      },
      {
        slug: "glp-protests-boundaries",
        name: "Protests & Boundaries",
        function: "protests",
        stages: (1..2),
        description: "Whole-phrase protests and boundary scripts for gestalt language processors.",
        tiles: ["no thank you", "stop please", "I don't want that", "not right now", "go away", "leave me alone"],
      },
      {
        slug: "glp-comments-observations",
        name: "Comments & Observations",
        function: "comments",
        stages: (1..3),
        description: "Whole-phrase comments and observations for gestalt language processors.",
        tiles: ["look at that!", "that's so funny", "I see it", "wow!", "that's cool", "what happened?"],
      },
      {
        slug: "glp-feelings-emotions",
        name: "Feelings & Emotions",
        function: "feelings",
        stages: (2..3),
        description: "Whole-phrase feelings and emotions for gestalt language processors.",
        tiles: ["I'm happy", "that makes me sad", "I feel mad", "I'm scared", "I'm excited", "I don't feel good"],
      },
      {
        slug: "glp-transitions-routines",
        name: "Transitions & Routines",
        function: "transitions",
        stages: (1..2),
        description: "Whole-phrase transition and routine scripts for gestalt language processors.",
        tiles: ["time to go", "all done", "what's next?", "first this then that", "almost time", "let's clean up"],
      },
    ].freeze

    module_function

    # Seeded GLP template boards, alphabetical. Empty in environments where the
    # seed hasn't run.
    def boards
      Board.where(is_template: true, category: CATEGORY).order(:name)
    end

    # The seeded GLP template board for a slug (e.g. "glp-greetings-social"),
    # or nil. The Board Builder build path uses this to resolve and clone a
    # GLP template — the catalog keys templates by slug, so this is what the
    # frontend sends back as `template`.
    def find_board(slug)
      return nil if slug.blank?

      boards.find_by(slug: slug)
    end

    # The seeded function boards in TEMPLATES (communicative-function) order —
    # the clone sources for the Board Builder's gestalt "Phrases" layer
    # (Boards::PhrasesPageBuilder). Empty when the seed hasn't run.
    def function_boards
      slugs = TEMPLATES.map { |t| t[:slug] }
      by_slug = boards.where(slug: slugs).index_by(&:slug)
      slugs.filter_map { |slug| by_slug[slug] }
    end

    # True when `slug` is a seeded GLP template board — used by the build path
    # to branch GLP templates away from robust sets / starter blueprints.
    def template_slug?(slug)
      return false if slug.blank?

      boards.exists?(slug: slug)
    end

    # Picker catalog entries (same shape family as StarterBlueprints#catalog,
    # with `kind: "glp"` so the frontend can group/badge them).
    def catalog
      boards.map { |board| catalog_entry(board) }
    end

    def catalog_entry(board)
      {
        key: board.slug,
        name: board.name,
        kind: "glp",
        category: CATEGORY,
        tags: board.tags,
        tiles: board.board_images.order(:position).map(&:label),
      }
    end

    # Slug of the most stage-appropriate template for a given NLA stage, or nil.
    # Definition-driven, so it works even before the boards are seeded; callers
    # that need a real board should also check `boards.exists?(slug:)`.
    def recommended_for(stage)
      return nil if stage.blank?

      defn = TEMPLATES.find { |t| t[:stages].include?(stage.to_i) }
      defn&.dig(:slug)
    end

    # Tags for a template definition: ["glp", "stage_1", "stage_2",
    # "communicative_function:<fn>"].
    def tags_for(defn)
      stage_tags = defn[:stages].map { |n| "stage_#{n}" }
      ["glp", *stage_tags, "communicative_function:#{defn[:function]}"]
    end

    # Create/refresh all six GLP template boards. Idempotent: upserts each board
    # by slug and only adds tiles whose phrase isn't already present.
    def seed!(admin: default_admin)
      raise "No admin user available for GLP template seeding" unless admin

      TEMPLATES.map { |defn| seed_board!(defn, admin) }
    end

    def seed_board!(defn, admin)
      board = Board.find_by(slug: defn[:slug]) || Board.new(slug: defn[:slug])
      board.assign_attributes(
        name: defn[:name],
        description: defn[:description],
        category: CATEGORY,
        user: admin,
        parent: admin,
        predefined: true,
        published: true,
        is_template: true,
        sub_board: false,
        board_type: BOARD_TYPE,
      )
      board.tags = tags_for(defn)
      board.save!

      existing = board.board_images.pluck(:label).compact.map(&:downcase)
      defn[:tiles].each do |phrase|
        next if existing.include?(phrase.downcase)

        image = find_or_create_phrase_image(phrase, admin)
        board.add_image(image.id)
      end

      board
    end

    # A whole-phrase Image tagged part_of_speech: "phrase" so the tile renders
    # (and downstream gating reads) as a gestalt script, not a single word.
    def find_or_create_phrase_image(phrase, admin)
      image = Image.find_by(label: phrase, user_id: admin.id) || Image.new(label: phrase, user_id: admin.id)
      image.part_of_speech = TILE_PART_OF_SPEECH
      image.save!
      image
    end

    def default_admin
      User.find_by(id: User::DEFAULT_ADMIN_ID) || User.where(role: "admin").order(:id).first
    end
  end
end
