module VideoBoards
  # Builds a predefined admin board whose tiles are YouTube video tiles — one
  # tile per entry. Shared by `lib/tasks/video_demo.rake` (curated boards) and
  # Admin::VideoBoardsController (admin-entered boards), so both produce
  # byte-for-byte the same kind of board.
  #
  # Config shape (URLs are already parsed — this service never sees a raw URL):
  #
  #   { name:, description:, tags: [], columns: Integer, settings: {},
  #     videos: [{ label:, youtube_id:, range: { "start_seconds" => .. } }, ...] }
  #
  # `range` is whatever BoardImage.parse_video_range returned: `{}` for "play
  # the whole video", or a hash of trim points. A `nil` range means the caller
  # accepted invalid input and must reject it before calling here.
  module BoardSeeder
    module_function

    # Boards are keyed on (name, admin, predefined) so a re-run finds the board
    # it seeded last time instead of creating a second one.
    def board_for(name, admin)
      Board.find_or_initialize_by(name: name, user_id: admin.id, predefined: true)
    end

    # Same reuse-don't-generate policy as core_boards: prefer an existing public
    # image with artwork, else create one without queuing generation.
    def find_or_build_image(label)
      matches = Image.default_public.where(label: label).order(:created_at)
      matches.find { |img| img.docs.any? } || matches.last ||
        Image.default_public.new(label: label) do |img|
          img.image_prompt = label
          unless img.save
            Rails.logger.warn "VideoBoards::BoardSeeder: failed to save image #{label.inspect}: #{img.errors.full_messages.join(", ")}"
          end
        end
    end

    # Seeds unpublished on purpose: `published` is what makes a predefined admin
    # board public (Board.public_boards, Board#viewable_by?), so leaving it false
    # keeps the board reviewable by the admin owner while invisible to everyone
    # else. Only set on create, so re-running never un-publishes a reviewed board.
    def configure_board!(board, admin, cfg)
      columns = cfg[:columns]
      board.assign_attributes(
        description: cfg[:description],
        predefined: true,
        board_type: "default",
        number_of_columns: columns,
        small_screen_columns: columns,
        medium_screen_columns: columns,
        large_screen_columns: columns,
        tags: cfg[:tags],
      )
      board.settings = (board.settings || {}).merge(cfg[:settings]) if cfg[:settings].present?
      board.published = false if board.new_record?
      board.parent = admin
      board.layout ||= {}
      board.generate_unique_slug if board.slug.blank?
      board.save!
      board
    end

    # Returns the created board_image, or nil when the tile couldn't be added
    # (Board#add_image returns nil on failure).
    def add_video_tile!(board, entry)
      image = find_or_build_image(entry[:label])
      return nil unless image&.id

      board_image = board.add_image(image.id)
      return nil unless board_image

      board_image.set_youtube_video!(entry[:youtube_id], entry[:range] || {})
      board_image
    end

    # Full build: configure → one video tile per entry → grid + word list.
    # Idempotent by name: a board that already has tiles is returned untouched
    # rather than getting a second set of tiles.
    def build_board!(cfg, admin:)
      board = board_for(cfg[:name], admin)
      return board if board.persisted? && board.board_images.exists?

      configure_board!(board, admin, cfg)
      added = cfg[:videos].map { |entry| [entry, add_video_tile!(board, entry)] }
      added.each do |entry, board_image|
        Rails.logger.warn "VideoBoards::BoardSeeder: could not add tile for #{entry[:label].inspect}" unless board_image
      end
      finalize!(board)
      board
    end

    def finalize!(board)
      board.update_column(:layout, {}) if board.layout.nil?
      %w[lg md sm].each { |screen| board.calculate_grid_layout_for_screen_size(screen, true) }
      board.set_current_word_list
      board.save!
      board
    end

    # Non-binding suggestion so a board of N tiles lands on a roughly square
    # grid. The caller (rake config or admin form) can always override it.
    def suggested_columns(video_count)
      case video_count
      when 0..4 then 2
      when 5..9 then 3
      when 10..16 then 4
      when 17..25 then 5
      else 6
      end
    end
  end
end
