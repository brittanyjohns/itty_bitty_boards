# Creates public "Core + X" boards: a fixed 20-word core vocabulary on the
# left half of an 8-column grid, paired with 20 topic words on the right.
# Modeled on the existing "Core + Lunch" board (8 columns x 5 rows, 40 tiles).
# Core tiles get a black border so they read as the stable vocabulary; topic
# tiles are borderless.
module CoreBoardsSeeder
  # The fixed 20-word core vocabulary. Order is row-major across the 4 core
  # columns: each line is one grid row. "I" stays capitalized intentionally.
  CORE_WORDS = %w[
    I want help yes
    you have give no
    he look go what
    she like in more
    they it on stop
  ].freeze

  COLUMNS = 8
  CORE_COLUMNS = 4
  CORE_VOICE = "polly:kevin".freeze
  CORE_BORDER_WIDTH = 5
  CORE_BORDER_COLOR = "#000000".freeze

  # Curated 20-word topic vocabularies (the right half). Any topic not listed
  # here falls back to AI word generation via Board#get_words_for_scenario.
  CURATED_TOPICS = {
    "Lunch" => {
      tags: ["restaurant", "home", "choice board", "school"],
      words: ["lunch", "eat", "hot", "cold", "food", "drink", "sauce", "fork",
              "napkin", "plate", "open", "close", "yummy", "yucky", "pour",
              "scoop", "poke", "bite", "more please", "all done"],
    },
    "Playground" => {
      tags: ["playground", "outdoors", "recess", "play"],
      words: ["swing", "slide", "climb", "run", "jump", "ball", "sand", "dig",
              "push", "catch", "my turn", "your turn", "up", "down", "fast",
              "friend", "fun", "careful", "fall", "all done"],
    },
    "Swimming" => {
      tags: ["swimming", "water", "pool", "summer"],
      words: ["swim", "splash", "float", "kick", "jump", "water", "pool",
              "towel", "goggles", "wet", "cold", "deep", "dive", "hold",
              "blow bubbles", "my turn", "help", "careful", "fun", "all done"],
    },
  }.freeze

  module_function

  # Resolves which topics to build from ENV: an explicit TOPICS list, a COUNT
  # of curated topics, or all curated topics when neither is given.
  def resolve_topics
    if ENV["TOPICS"].present?
      ENV["TOPICS"].split(",").map { |t| normalize_topic(t) }.reject(&:blank?)
    elsif ENV["COUNT"].present?
      count = ENV["COUNT"].to_i.clamp(0, CURATED_TOPICS.size)
      CURATED_TOPICS.keys.first(count)
    else
      CURATED_TOPICS.keys
    end
  end

  def normalize_topic(raw)
    raw.to_s.strip.split(/\s+/).map(&:capitalize).join(" ")
  end

  # Case-insensitive lookup into CURATED_TOPICS; nil for AI-fallback topics.
  def curated_topic(topic)
    _name, data = CURATED_TOPICS.find { |name, _| name.casecmp?(topic) }
    data
  end

  def board_tags(topic, curated)
    base = ["core words", "beginner", "featured"]
    extra = curated ? curated[:tags] : [topic.downcase]
    (base + extra).uniq
  end

  def board_description(topic)
    "Core vocabulary paired with #{topic.downcase} words — an 8-column starter " \
    "board with 20 fixed core words on the left and 20 #{topic.downcase} words " \
    "on the right."
  end

  # Reuses an existing image with artwork when one exists; otherwise an image
  # without artwork (the tile renders a placeholder). No image generation is
  # queued here on purpose.
  def find_or_build_image(label)
    matches = Image.default_public.where(label: label).order(:created_at)
    matches.find { |img| img.docs.any? } || matches.last ||
      Image.default_public.new(label: label) do |img|
        img.image_prompt = label
        unless img.save
          Rails.logger.warn "core_boards: failed to save image #{label.inspect}: #{img.errors.full_messages.join(", ")}"
        end
      end
  end

  # Asks OpenAI for topic words, normalizes them, and drops any that collide
  # with the core vocabulary.
  def ai_topic_words(board, topic, age_range)
    raw = board.get_words_for_scenario(topic, age_range, 24)
    return [] if raw.blank?

    core_down = CORE_WORDS.map(&:downcase)
    raw.map { |w| w.to_s.strip.downcase }
       .reject(&:blank?)
       .uniq
       .reject { |w| core_down.include?(w) }
  end

  def configure_board!(board, admin, topic, curated)
    board.assign_attributes(
      description: board_description(topic),
      predefined: true,
      published: true,
      voice: CORE_VOICE,
      board_type: "default",
      number_of_columns: COLUMNS,
      small_screen_columns: COLUMNS,
      medium_screen_columns: COLUMNS,
      large_screen_columns: COLUMNS,
      margin_settings: {
        "lg" => { "x" => 3, "y" => 3 },
        "md" => { "x" => 3, "y" => 3 },
        "sm" => { "x" => 3, "y" => 3 },
      },
      tags: board_tags(topic, curated),
    )
    board.parent = admin
    board.layout ||= {}
    board.generate_unique_slug if board.slug.blank?
    board.save!
    board
  end

  # Adds the 40 tiles in row-major order (4 core, then 4 topic, per row),
  # recomputes a clean 8-wide grid, and applies the core/topic border style.
  def add_tiles!(board, topic_words)
    rows = CORE_WORDS.size / CORE_COLUMNS
    interleaved = []
    rows.times do |r|
      interleaved.concat(CORE_WORDS[r * CORE_COLUMNS, CORE_COLUMNS])
      interleaved.concat(topic_words[r * CORE_COLUMNS, CORE_COLUMNS])
    end

    interleaved.each do |word|
      image = find_or_build_image(word)
      board.add_image(image.id)
    end

    board.update_column(:layout, {}) if board.layout.nil?
    %w[lg md sm].each { |screen| board.calculate_grid_layout_for_screen_size(screen, true) }

    apply_tile_borders!(board)

    board.set_current_word_list
    board.save!
  end

  # Core tiles occupy the left CORE_COLUMNS of each row and get a black border;
  # topic tiles are borderless.
  def apply_tile_borders!(board)
    board.board_images.order(:position).each do |bi|
      if (bi.position % COLUMNS) < CORE_COLUMNS
        bi.update_columns(border_width: CORE_BORDER_WIDTH, border_color: CORE_BORDER_COLOR)
      else
        bi.update_columns(border_width: 0, border_color: nil)
      end
    end
  end

  def attach_coaching_prompt_set!(board)
    return unless defined?(CoachingPromptSet) && CoachingPromptSet.respond_to?(:match_for)

    cps = CoachingPromptSet.match_for(board)
    return unless cps

    meta = (board.metadata || {}).merge("coaching_prompt_set_id" => cps.id)
    board.update_column(:metadata, meta)
  rescue => e
    Rails.logger.warn "core_boards: coaching prompt match failed for board #{board.id}: #{e.message}"
  end
end

namespace :core_boards do
  desc "Create public 'Core + X' boards (20 core words + 20 topic words). " \
       "ENV: TOPICS='Playground,Swimming' | COUNT=3 | AGE_RANGE='5-10' | DRY_RUN=1" \
       "Usage: bin/rails core_boards:seed"
  task seed: :environment do
    ActiveRecord::Base.logger.level = Logger::WARN
    admin = User.find(User::DEFAULT_ADMIN_ID)
    age_range = ENV["AGE_RANGE"].presence || "5-10"
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase)
    topics = CoreBoardsSeeder.resolve_topics

    puts ""
    puts "=" * 60
    puts "Core + X board seeding"
    puts "=" * 60
    puts "  Admin user: #{admin.email} (id=#{admin.id})"
    puts "  Topics (#{topics.size}): #{topics.join(", ")}"
    puts "  DRY RUN — no database writes, no API calls" if dry_run
    puts ""

    abort "No topics resolved. Pass TOPICS='A,B' or COUNT=n." if topics.empty?

    created = 0
    skipped = 0
    failed = 0

    topics.each do |topic|
      board_name = "Core + #{topic}"
      board = Board.find_or_initialize_by(name: board_name, user_id: admin.id, predefined: true)

      if board.persisted? && board.board_images.exists?
        puts "  skipped: #{board_name} (already has #{board.board_images.count} tiles)"
        skipped += 1
        next
      end

      curated = CoreBoardsSeeder.curated_topic(topic)
      source = curated ? "curated" : "AI-generated"

      if dry_run
        puts "  would create: #{board_name} (#{source} topic words)"
        next
      end

      CoreBoardsSeeder.configure_board!(board, admin, topic, curated)

      topic_words = if curated
          curated[:words]
        else
          CoreBoardsSeeder.ai_topic_words(board, topic, age_range)
        end

      need = CoreBoardsSeeder::CORE_WORDS.size
      if topic_words.blank? || topic_words.size < need
        got = topic_words&.size.to_i
        puts "  ERROR: #{board_name} — only #{got} topic word(s) available, need #{need}. " \
             "Skipped (board left unpublished; pass curated words or re-run)."
        board.update_columns(published: false)
        failed += 1
        next
      end

      topic_words = topic_words.first(need)
      CoreBoardsSeeder.add_tiles!(board, topic_words)
      CoreBoardsSeeder.attach_coaching_prompt_set!(board)

      board.reload
      puts "  created: #{board_name} (id=#{board.id}, slug=#{board.slug}, " \
           "#{board.board_images.count} tiles, #{source})"
      created += 1
    end

    puts ""
    unless dry_run
      puts "Done. created=#{created} skipped=#{skipped} failed=#{failed}"
      puts "Tiles reuse existing artwork only — no image generation was queued."
      puts "Words without artwork render as placeholders until artwork is added."
    end
    puts ""
  end
end
