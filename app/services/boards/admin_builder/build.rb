module Boards
  module AdminBuilder
    # Writes the board set an AdminBoardBuild describes. Runs from
    # BuildAdminBoardJob, after a human has looked at the art preview.
    #
    # Everything that touches the database happens in one transaction, so a bad
    # image id aborts the whole build rather than silently producing a short
    # board or a half-linked set. AI generation is queued AFTER the commit —
    # Sidekiq can otherwise pick the job up before the rows it references exist.
    #
    # **Linking is a deliberate three-pass, not a build order.** Every page's
    # Board row is created first, then tiles, then `predictive_board_id` is set.
    # `build_board.py` needs a topological `build_order()` with cycle-breaking
    # because its HTTP API creates a board *together with* its tiles, so it can't
    # name a board that doesn't exist yet. In-process that constraint doesn't
    # exist: linking is already a separate `update!` (the same shape
    # `Boards::BoardTreeBuilder` uses). Creating the shells up front makes
    # cycles — a child's "back to home" tile pointing at the root, two children
    # linking to each other — structurally impossible to get wrong, instead of
    # something a cycle-breaking heuristic has to guess its way out of.
    class Build
      class BuildError < StandardError; end

      def initialize(admin_board_build:)
        @build = admin_board_build
      end

      def call
        return build.board if build.board_id.present?

        build.mark_building!
        root = ActiveRecord::Base.transaction { create_set! }

        blank_image_ids = art_less_image_ids
        build.update!(board: root, status: "complete", art_report: art_report(root, blank_image_ids))
        queue_missing_art!(root, blank_image_ids)

        root
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

      def pages = build.pages

      def multi_page? = pages.size > 1

      # Keyed by the resolver's own normalized key, so a label looks up the same
      # way regardless of the casing it was authored in. Here it is correct that
      # a miss creates a blank Image — those blanks are what generation targets.
      # One batch for the whole set: the same word on two pages is one Image.
      def resolved
        @resolved ||= Boards::ImageResolver.resolve_all(Plan.labels(pages), owner: admin)
      end

      def create_set!
        # Pass 1 — every page's Board row, so pass 3 can link in any direction.
        boards = pages.index_with { |page| new_board(page) }.transform_keys { |page| page[:key] }

        # Pass 2 — tiles, in authored reading order per page.
        tiles_by_key = pages.to_h do |page|
          [page[:key], page[:tiles].map { |tile| add_tile!(boards[page[:key]], tile) }]
        end
        pages.each { |page| apply_reading_order!(boards[page[:key]], tiles_by_key[page[:key]], page) }

        # Pass 3 — folder links. Every target already exists, cycles included.
        link_pages!(boards, tiles_by_key)

        pages.each do |page|
          board = boards[page[:key]]
          board.set_current_word_list
          board.save!
        end

        @built_boards = boards
        boards[Plan::ROOT_KEY]
      end

      def new_board(page)
        root = Plan.root?(page)
        columns = page[:columns].to_i

        board = Board.new(
          name: page[:name],
          user: admin,
          parent: admin,
          # Only the root belongs in the public catalogue: `Board.public_boards`
          # keys on `predefined`, and a set whose every folder page showed up
          # there as a standalone board would bury the board it belongs to.
          # Child pages stay reachable because `Board#viewable_by?` gates on
          # `published` alone.
          predefined: root,
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
          settings: settings_for(page),
          # Catalogue metadata belongs to the root alone: child pages are
          # created with `predefined: false` and never appear in
          # `Board.public_boards`, so tagging them would fill the public tag
          # filter with folder-page noise.
          description: root ? build.description : nil,
          tags: root ? Array(build.tags) : [],
        )
        # Assigns only — a collision gets a hex suffix rather than an error, so
        # the final slug is worth surfacing in the UI.
        board.generate_unique_slug if board.slug.blank?
        board.save!
        board
      end

      def settings_for(page)
        settings = { AdminBoardBuild::BUILDER_SETTING => true, "disable_scroll" => true }
        return settings unless multi_page?

        if Plan.root?(page)
          # A child's "back to home" tile makes the root look like a sub-board to
          # `Board#check_is_sub_board`, which would drop it out of the main-board
          # scopes. `builder_root` is the existing flag for exactly that: pin it
          # as a main board regardless of who links to it.
          settings.merge("builder_root" => true)
        else
          settings.merge("builder_child" => true)
        end
      end

      def add_tile!(board, tile)
        label = tile[:label].to_s
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
        pos = tile[:part_of_speech].to_s
        attrs[:part_of_speech] = pos if pos.present? && pos != "default"

        display_label = tile[:display_label].to_s
        attrs[:display_label] = display_label if display_label.present?

        board_image.update!(attrs) if attrs.any?
      end

      # A tile becomes a folder when its predictive_board_id points at another
      # board — the same one-line link Boards::BoardTreeBuilder makes.
      def link_pages!(boards, tiles_by_key)
        pages.each do |page|
          page[:tiles].each_with_index do |tile, index|
            target = tile[:links_to].presence
            next if target.nil?

            child = boards[target]
            raise BuildError, "tile #{tile[:label].inspect} links to unknown page #{target.inspect}" if child.nil?

            tiles_by_key[page[:key]][index].update!(predictive_board_id: child.id)
          end
        end
      end

      # Reading order: left to right, top to bottom, in the order the words were
      # authored. apply_layout! sorts by [y, x] and rewrites every tile's
      # position, so the layout — not creation order — decides the final order.
      def apply_reading_order!(board, board_images, page)
        columns = page[:columns].to_i
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

      def art_report(root, blank_image_ids)
        total = Plan.labels(pages).size
        missing = resolved.select { |_, image| blank_image_ids.include?(image.id) }.keys

        {
          "tile_count" => total,
          "with_art" => total - missing.size,
          "coverage_pct" => total.zero? ? 0 : (((total - missing.size) / total.to_f) * 100).round,
          "missing_labels" => missing,
          "queued_image_ids" => blank_image_ids,
          "slug" => root.slug,
          # key => board id, so `show` can list every page of the set and
          # publish can cascade over it without re-walking the link graph.
          "boards" => @built_boards.transform_values(&:id),
        }
      end

      # Queued after commit: Sidekiq can otherwise pick the job up before the
      # rows it references exist.
      def queue_missing_art!(root, image_ids)
        ArtQueue.call(board: root, image_ids: image_ids, topic: build.topic)
      end
    end
  end
end
