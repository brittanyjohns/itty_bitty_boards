module Boards
  module AdminBuilder
    # Writes the board an AdminBoardBuild describes. Runs from
    # BuildAdminBoardJob, after a human has looked at the art preview.
    #
    # Everything that touches the database happens in one transaction, so a bad
    # image id aborts the whole build rather than silently producing a short
    # board. AI generation is queued AFTER the commit — Sidekiq can otherwise
    # pick the job up before the rows it references exist.
    class Build
      class BuildError < StandardError; end

      # Matches API::Internal::BoardImagesController's slicing: the job fans out
      # to an image API and a whole 48-tile board in one call would stampede it.
      GENERATE_BATCH_SIZE = 3

      def initialize(admin_board_build:)
        @build = admin_board_build
      end

      def call
        return build.board if build.board_id.present?

        build.mark_building!
        board = ActiveRecord::Base.transaction { create_board! }

        blank_image_ids = art_less_image_ids
        build.update!(board: board, status: "complete", art_report: art_report(board, blank_image_ids))
        queue_missing_art!(board, blank_image_ids)

        board
      rescue StandardError => e
        build.mark_failed!(e.message)
        raise
      end

      private

      attr_reader :build

      def admin
        @admin ||= User.find_by(id: User::DEFAULT_ADMIN_ID) ||
                   raise(BuildError, "No default admin user configured — cannot build.")
      end

      def tiles = build.tiles

      def columns = build.columns_count.to_i

      # Keyed by the resolver's own normalized key, so a label looks up the same
      # way regardless of the casing it was authored in. Here it is correct that
      # a miss creates a blank Image — those blanks are what generation targets.
      def resolved
        @resolved ||= Boards::ImageResolver.resolve_all(build.labels, owner: admin)
      end

      def create_board!
        board = new_board
        board_images = tiles.map { |tile| add_tile!(board, tile) }
        apply_reading_order!(board, board_images)
        board.set_current_word_list
        board.save!
        board
      end

      def new_board
        board = Board.new(
          name: build.name,
          user: admin,
          parent: admin,
          predefined: true,
          published: false,
          board_type: "static",
          # Set at create time: assigning `voice` later cascades to every tile
          # and re-queues all their audio.
          voice: build.voice,
          # lg is authored; md and sm are DERIVED from it through the single
          # source of truth. `Board#set_screen_sizes` would do this itself, but
          # only when the column is nil — and boards.medium/small_screen_columns
          # carry non-nil database defaults (8 and 3), so leaving them alone
          # gives a 6-column board an 8-column tablet layout. Deriving here is
          # not the same as hand-authoring a md/sm *layout*, which is what marks
          # a screen customized and stops reflow for good.
          large_screen_columns: columns,
          medium_screen_columns: Boards::ScreenColumns.derive(columns, "md"),
          small_screen_columns: Boards::ScreenColumns.derive(columns, "sm"),
          number_of_columns: columns,
          settings: { AdminBoardBuild::BUILDER_SETTING => true, "disable_scroll" => true },
        )
        # Assigns only — a collision gets a hex suffix rather than an error, so
        # the final slug is worth surfacing in the UI.
        board.generate_unique_slug if board.slug.blank?
        board.save!
        board
      end

      def add_tile!(board, tile)
        label = tile["label"].to_s
        image = resolved[Boards::ImageResolver.normalize(label)]
        raise BuildError, "no image resolved for #{label.inspect}" if image.nil?

        # Board#add_image returns nil on a missing image or a failed save rather
        # than raising, which would leave a short board behind.
        board_image = board.add_image(image.id)
        raise BuildError, "could not add a tile for #{label.inspect}" if board_image.nil?

        apply_tile_attributes!(board_image, tile)
        board_image
      end

      # `BoardImage#set_colors` is `before_update ... if: :part_of_speech_changed?`
      # — before_update, so it does not fire on create. On the create path colors
      # come from the Image's own bg_color, not the part of speech, so applying
      # the authored part of speech as a separate update after the tile exists is
      # what actually lands the Modified Fitzgerald colour. Don't also pass
      # bg_color; the callback would overwrite it.
      def apply_tile_attributes!(board_image, tile)
        attrs = {}
        pos = tile["part_of_speech"].to_s
        attrs[:part_of_speech] = pos if pos.present? && pos != "default"

        display_label = tile["display_label"].to_s
        attrs[:display_label] = display_label if display_label.present?

        board_image.update!(attrs) if attrs.any?
      end

      # Reading order: left to right, top to bottom, in the order the words were
      # authored. apply_layout! sorts by [y, x] and rewrites every tile's
      # position, so the layout — not creation order — decides the final order.
      def apply_reading_order!(board, board_images)
        layout = board_images.each_with_index.map do |board_image, index|
          {
            "i" => board_image.id.to_s,
            "x" => index % columns,
            "y" => index / columns,
            "w" => 1,
            "h" => 1,
          }
        end
        return if layout.empty?

        board.apply_layout!(layout: layout, screen_size: "lg", columns: { large_screen_columns: columns })
      end

      # Labels that resolved to a blank Image — the ones generation targets.
      def art_less_image_ids
        Image.where(id: resolved.values.map(&:id).uniq).where.missing(:docs).pluck(:id)
      end

      def art_report(board, blank_image_ids)
        total = tiles.size
        missing = resolved.select { |_, image| blank_image_ids.include?(image.id) }.keys

        {
          "tile_count" => total,
          "with_art" => total - missing.size,
          "coverage_pct" => total.zero? ? 0 : (((total - missing.size) / total.to_f) * 100).round,
          "missing_labels" => missing,
          "queued_image_ids" => blank_image_ids,
          "slug" => board.slug,
        }
      end

      # Queued after commit, in slices of 3, mirroring
      # API::Internal::BoardImagesController#queue_missing_art!.
      def queue_missing_art!(board, image_ids)
        return if image_ids.empty?

        seed_art_prompts!(image_ids)
        image_ids.each_slice(GENERATE_BATCH_SIZE) do |batch|
          GenerateImagesJob.perform_async(batch, board.id)
        end
      end

      # The board's topic is what keeps "swing" on a playground board from
      # coming back as a mood swing. `image_prompt` carries the INTENT only —
      # Images::PromptBuilder composes the house style envelope at generation
      # time and must never have it baked in here, or it gets wrapped twice.
      def seed_art_prompts!(image_ids)
        Image.where(id: image_ids).each do |image|
          next if image.image_prompt.present?

          image.update_column(:image_prompt, art_intent_for(image.label))
        end
      end

      def art_intent_for(label)
        topic = build.topic.to_s.strip
        return label.to_s if topic.blank?

        "#{label} in the context of #{topic}"
      end
    end
  end
end
