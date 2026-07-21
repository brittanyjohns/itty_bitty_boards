# Seeds the predefined video demo boards: one tile per curated video. Tapping
# a tile speaks its label and then opens the video in the tile video modal
# (data["video"] config — see BoardImage#video_config).
module VideoDemoSeeder
  # Curated kid-safe videos, one entry per board. REVIEW BEFORE PUBLISHING:
  # every video must be hand-verified (plays, is the intended video, embeds
  # allowed) — YouTube ids are not guessable and links rot. Seeding validates
  # URL shape via YoutubeUrlParser and fails loudly on malformed entries, but
  # it cannot judge content. Boards seed unpublished so they can be reviewed
  # first; `video_demo:publish BOARD=<key>` makes one public.
  BOARDS = {
    "songs" => {
      name: "Video Demo",
      description: "A demo board of sing-along videos — tap a tile to hear the " \
                   "word and watch the video.",
      tags: ["videos", "songs", "demo"],
      columns: 3,
      videos: [
        { label: "Baby Shark", url: "https://www.youtube.com/watch?v=XqZsoesa55w" },
        { label: "Wheels on the Bus", url: "https://www.youtube.com/watch?v=e_04ZrNroTo" },
        { label: "Twinkle Twinkle", url: "https://www.youtube.com/watch?v=yCjJyiqpAuU" },
        { label: "Happy and You Know It", url: "https://www.youtube.com/watch?v=l4WNrvVjiTw" },
        { label: "Head Shoulders Knees and Toes", url: "https://www.youtube.com/watch?v=h4eueDYPTIg" },
        { label: "Old MacDonald", url: "https://www.youtube.com/watch?v=_6HzoUcx3eo" },
        { label: "Itsy Bitsy Spider", url: "https://www.youtube.com/watch?v=w_lCi8U49mY" },
        { label: "Five Little Ducks", url: "https://www.youtube.com/watch?v=pZw9veQ76fo" },
        { label: "Row Row Row Your Boat", url: "https://www.youtube.com/watch?v=7otAJa3jui8" },
        { label: "BINGO", url: "https://www.youtube.com/watch?v=9mmF8zOlh_g" },
      ],
    },
    # Core words paired with the ASL sign for each. This is the clearest case
    # for video tiles: a sign is motion, so a static symbol cannot show it.
    # Labels are deliberately core vocabulary, so the tiles reuse the existing
    # AAC artwork for those words instead of generating new images.
    "asl" => {
      name: "ASL Signs Demo",
      description: "Core words with the ASL sign for each — tap a tile to hear " \
                   "the word and watch how to sign it.",
      tags: ["videos", "asl", "sign language", "demo"],
      columns: 4,
      videos: [
        { label: "more", url: "https://www.youtube.com/watch?v=34CBy8zipZQ" },
        { label: "help", url: "https://www.youtube.com/watch?v=XM1nr6IkcBE" },
        { label: "eat", url: "https://www.youtube.com/watch?v=04FuU1RxG3E" },
        { label: "drink", url: "https://www.youtube.com/watch?v=UqyS59psrNE" },
        { label: "play", url: "https://www.youtube.com/watch?v=i97PA_UGApo" },
        { label: "all done", url: "https://www.youtube.com/watch?v=YEFNwQZo7Wg" },
        { label: "toy", url: "https://www.youtube.com/watch?v=5UdCpYcSoAc" },
        { label: "fun", url: "https://www.youtube.com/watch?v=rByGnEU8sFM" },
      ],
    },
  }.freeze

  module_function

  def board_keys
    BOARDS.keys
  end

  # Resolves the BOARD env var to one key or all of them. Raises on an unknown
  # key rather than silently seeding nothing.
  def resolve_keys(raw)
    return board_keys if raw.blank?

    key = raw.to_s.strip.downcase
    unless BOARDS.key?(key)
      raise "video_demo: unknown BOARD #{raw.inspect} — valid keys: #{board_keys.join(", ")}"
    end
    [key]
  end

  def config_for(key)
    BOARDS.fetch(key)
  end

  # The board-building logic lives in VideoBoards::BoardSeeder so the admin
  # controller can reuse it; this module is just the curated config + CLI shell.
  def board_for(key, admin)
    VideoBoards::BoardSeeder.board_for(config_for(key)[:name], admin)
  end

  # Parses every curated URL up front so a typo fails before any writes.
  def parse_videos!(cfg)
    cfg[:videos].map do |entry|
      youtube_id = YoutubeUrlParser.video_id(entry[:url])
      raise "video_demo: unparseable YouTube URL for #{entry[:label].inspect}: #{entry[:url]}" unless youtube_id
      entry.merge(youtube_id: youtube_id)
    end
  end
end

namespace :video_demo do
  desc "Create the unpublished video demo boards (curated kid-safe YouTube tiles). " \
       "Idempotent — skips a board that already has tiles. " \
       "ENV: BOARD=#{VideoDemoSeeder.board_keys.join("|")} (default: all), DRY_RUN=1. " \
       "Usage: bin/rails video_demo:seed"
  task seed: :environment do
    ActiveRecord::Base.logger.level = Logger::WARN
    admin = User.find(User::DEFAULT_ADMIN_ID)
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase)
    keys = VideoDemoSeeder.resolve_keys(ENV["BOARD"])

    puts ""
    puts "=" * 60
    puts "Video demo board seeding#{dry_run ? " (DRY RUN)" : ""}"
    puts "=" * 60
    puts "  Admin user: #{admin.email} (id=#{admin.id})"

    seeded = []
    keys.each do |key|
      cfg = VideoDemoSeeder.config_for(key)
      parsed = VideoDemoSeeder.parse_videos!(cfg)

      puts ""
      puts "  [#{key}] #{cfg[:name]} — #{parsed.size} videos"

      board = VideoDemoSeeder.board_for(key, admin)
      if board.persisted? && board.board_images.exists?
        puts "    Already seeded (id=#{board.id}, #{board.board_images.count} tiles) — skipping."
        next
      end
      next if dry_run

      VideoBoards::BoardSeeder.configure_board!(board, admin, cfg)
      parsed.each do |entry|
        if VideoBoards::BoardSeeder.add_video_tile!(board, entry)
          puts "    + #{entry[:label]} (#{entry[:youtube_id]})"
        else
          puts "    ! could not add tile for #{entry[:label].inspect} — skipped"
        end
      end

      VideoBoards::BoardSeeder.finalize!(board)
      seeded << key
      puts "    Done: board id=#{board.id}, slug=#{board.slug}, #{board.board_images.count} tiles."
    end

    next if dry_run || seeded.empty?

    puts ""
    puts "  UNPUBLISHED — visible to you as the admin owner, not to anyone else."
    puts "  Review, then publish each with:"
    seeded.each { |key| puts "    bin/rails video_demo:publish BOARD=#{key}" }
  end

  desc "Publish a demo board after review — this makes it public. " \
       "ENV: BOARD=#{VideoDemoSeeder.board_keys.join("|")} (required). " \
       "Usage: bin/rails video_demo:publish BOARD=asl"
  task publish: :environment do
    # BOARD is required here, unlike seed: publishing is public-facing, so it
    # must never happen to a board the caller didn't name.
    if ENV["BOARD"].blank?
      puts "BOARD is required. Usage: bin/rails video_demo:publish BOARD=<#{VideoDemoSeeder.board_keys.join("|")}>"
      next
    end
    admin = User.find(User::DEFAULT_ADMIN_ID)
    key = VideoDemoSeeder.resolve_keys(ENV["BOARD"]).first
    board = VideoDemoSeeder.board_for(key, admin)

    if board.new_record?
      puts "No '#{VideoDemoSeeder.config_for(key)[:name]}' board found — run video_demo:seed BOARD=#{key} first."
      next
    end
    if board.published?
      puts "'#{board.name}' (id=#{board.id}) is already published."
      next
    end
    if board.board_images.empty?
      puts "'#{board.name}' (id=#{board.id}) has no tiles — refusing to publish an empty board."
      next
    end

    board.update!(published: true)
    puts "Published '#{board.name}' (id=#{board.id}, slug=#{board.slug}) — it is now public."
  end

  desc "Unpublish a demo board (reverses video_demo:publish). " \
       "ENV: BOARD=#{VideoDemoSeeder.board_keys.join("|")} (required). " \
       "Usage: bin/rails video_demo:unpublish BOARD=asl"
  task unpublish: :environment do
    if ENV["BOARD"].blank?
      puts "BOARD is required. Usage: bin/rails video_demo:unpublish BOARD=<#{VideoDemoSeeder.board_keys.join("|")}>"
      next
    end
    admin = User.find(User::DEFAULT_ADMIN_ID)
    key = VideoDemoSeeder.resolve_keys(ENV["BOARD"]).first
    board = VideoDemoSeeder.board_for(key, admin)

    if board.new_record?
      puts "No '#{VideoDemoSeeder.config_for(key)[:name]}' board found."
      next
    end

    board.update!(published: false)
    puts "Unpublished '#{board.name}' (id=#{board.id}) — no longer public."
  end
end
