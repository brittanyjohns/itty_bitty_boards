# Seeds the predefined "Video Demo" board: one tile per curated kid-safe
# YouTube video. Tapping a tile speaks its label and then opens the video in
# the tile video modal (data["video"] config — see BoardImage#video_config).
module VideoDemoSeeder
  BOARD_NAME = "Video Demo".freeze
  COLUMNS = 3

  # Curated kid-safe videos. REVIEW BEFORE SEEDING PRODUCTION: every entry
  # must be hand-verified (plays, is the intended video, embeds allowed) —
  # YouTube ids are not guessable and links rot. The seed task validates URL
  # shape via YoutubeUrlParser and fails loudly on malformed entries, but it
  # cannot verify content.
  CURATED_VIDEOS = [
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
  ].freeze

  module_function

  # Same reuse-don't-generate policy as core_boards: prefer an existing public
  # image with artwork, else create one without queuing generation.
  def find_or_build_image(label)
    matches = Image.default_public.where(label: label).order(:created_at)
    matches.find { |img| img.docs.any? } || matches.last ||
      Image.default_public.new(label: label) do |img|
        img.image_prompt = label
        unless img.save
          Rails.logger.warn "video_demo: failed to save image #{label.inspect}: #{img.errors.full_messages.join(", ")}"
        end
      end
  end

  def configure_board!(board, admin)
    board.assign_attributes(
      description: "A demo board of sing-along videos — tap a tile to hear the " \
                   "word and watch the video.",
      predefined: true,
      published: true,
      board_type: "default",
      number_of_columns: COLUMNS,
      small_screen_columns: COLUMNS,
      medium_screen_columns: COLUMNS,
      large_screen_columns: COLUMNS,
      tags: ["videos", "songs", "demo"],
    )
    board.parent = admin
    board.layout ||= {}
    board.generate_unique_slug if board.slug.blank?
    board.save!
    board
  end
end

namespace :video_demo do
  desc "Create the public 'Video Demo' board (curated kid-safe YouTube tiles). " \
       "Idempotent — skips when the board already has tiles. ENV: DRY_RUN=1. " \
       "Usage: bin/rails video_demo:seed"
  task seed: :environment do
    ActiveRecord::Base.logger.level = Logger::WARN
    admin = User.find(User::DEFAULT_ADMIN_ID)
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase)

    # Fail loudly on a malformed curated entry before touching the database.
    parsed = VideoDemoSeeder::CURATED_VIDEOS.map do |entry|
      youtube_id = YoutubeUrlParser.video_id(entry[:url])
      raise "video_demo: unparseable YouTube URL for #{entry[:label].inspect}: #{entry[:url]}" unless youtube_id
      entry.merge(youtube_id: youtube_id)
    end

    puts ""
    puts "=" * 60
    puts "Video Demo board seeding#{dry_run ? " (DRY RUN)" : ""}"
    puts "=" * 60
    puts "  Admin user: #{admin.email} (id=#{admin.id})"
    puts "  Videos (#{parsed.size}): #{parsed.map { |v| v[:label] }.join(", ")}"

    board = Board.find_or_initialize_by(
      name: VideoDemoSeeder::BOARD_NAME, user_id: admin.id, predefined: true,
    )
    if board.persisted? && board.board_images.exists?
      puts "  Board already seeded (id=#{board.id}, #{board.board_images.count} tiles) — skipping."
      next
    end
    next if dry_run

    VideoDemoSeeder.configure_board!(board, admin)
    parsed.each do |entry|
      image = VideoDemoSeeder.find_or_build_image(entry[:label])
      board_image = board.add_image(image.id)
      unless board_image
        puts "  ! could not add tile for #{entry[:label].inspect} — skipped"
        next
      end
      board_image.set_youtube_video!(entry[:youtube_id])
      puts "  + #{entry[:label]} (#{entry[:youtube_id]})"
    end

    board.update_column(:layout, {}) if board.layout.nil?
    %w[lg md sm].each { |screen| board.calculate_grid_layout_for_screen_size(screen, true) }
    board.set_current_word_list
    board.save!

    puts "  Done: board id=#{board.id}, slug=#{board.slug}, #{board.board_images.count} tiles."
  end
end
