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
        # Already built. A build that died while finishing keeps its set and
        # stays "failed" — the boards exist, and rebuilding them is the one
        # thing that must not happen. The page's "Regenerate art" action is the
        # recovery path for the art that never got queued.
        return build.board if build.board_id.present?

        root = create_and_claim!
        # Another worker got there first and owns finishing this build.
        return build.board if root.nil?

        finish!(root)
        root
      rescue StandardError => e
        build.mark_failed!(e.message)
        raise
      end

      private

      attr_reader :build

      # The set and the build's pointer AT the set commit together, under a row
      # lock on the build. Both halves are load-bearing — each one missing
      # leaves a way to build the same set twice:
      #
      #   * **The claim is inside the transaction** because everything after it
      #     can raise (two art queries and a jsonb write) and
      #     BuildAdminBoardJob is `retry: 2`. With the claim outside, a failure
      #     in that window left the boards committed but `board_id` still
      #     blank, so the retry sailed straight past the guard and built a
      #     second full set — root and every page. The orphaned first set stays
      #     `published: true` and appears in no build's `art_report`, so
      #     `set_boards` can't see it: it isn't listed on the build page,
      #     publish/unpublish skip it, and destroying the build leaves it
      #     behind. `rake admin_board_builds:orphans` finds the ones already
      #     shipped this way.
      #   * **The row lock** is what makes the guard mean anything with two
      #     workers at once. Sidekiq delivers at least once, so two attempts can
      #     both read a blank `board_id` before either writes one.
      def create_and_claim!
        build.with_lock do
          next nil if build.board_id.present?

          build.update!(status: "building", error_message: nil)
          created = create_set!
          # EVERY page, not just the root. `set_boards` reads
          # art_report["boards"] and falls back to `[board_id]` alone, so a
          # build that died before the full report was written owned its root
          # and disowned its pages: destroy left them behind and
          # publish/unpublish skipped them. `finish!` overwrites this with the
          # complete report, which carries the same key.
          build.update!(board: created, art_report: { "boards" => built_board_ids })
          created
        end
      end

      def built_board_ids
        @built_boards.transform_values(&:id)
      end

      # Everything that is safe to redo. Deliberately outside the claim: none of
      # it creates a board, so a failure here costs a retry rather than a
      # duplicate set.
      def finish!(root)
        blank_image_ids = art_less_image_ids
        regenerate_ids = regenerate_image_ids(blank_image_ids)
        build.update!(status: "complete", art_report: art_report(root, blank_image_ids, regenerate_ids))
        unpin_regenerated_tiles!(regenerate_ids)
        queue_missing_art!(root, blank_image_ids)
        queue_regenerated_art!(root, regenerate_ids)
      end

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

      # Pages this build writes, and pages that just point at a board someone
      # already published. A linked page is a link and nothing else — no Board
      # row, no tiles, no layout — so it is held apart from `@built_boards`,
      # which is what `art_report["boards"]` and therefore
      # `AdminBoardBuild#set_boards` are built from. Publish, unpublish and
      # destroy all iterate that list, and none of them may reach a board this
      # build doesn't own.
      def owned_pages = pages.reject { |page| Plan.linked?(page) }

      def create_set!
        # Pass 1 — every page's Board row, so pass 3 can link in any direction.
        boards = owned_pages.index_with { |page| new_board(page) }.transform_keys { |page| page[:key] }
        @built_boards = boards
        @linked_boards = resolve_linked_boards!

        # Pass 2 — tiles, in authored reading order per page.
        tiles_by_key = owned_pages.to_h do |page|
          [page[:key], page[:tiles].map { |tile| add_tile!(boards[page[:key]], tile) }]
        end
        owned_pages.each { |page| apply_reading_order!(boards[page[:key]], tiles_by_key[page[:key]], page) }

        # Pass 3 — folder links. Every target already exists, cycles included.
        link_pages!(boards.merge(@linked_boards), tiles_by_key)

        owned_pages.each do |page|
          board = boards[page[:key]]
          board.set_current_word_list
          board.save!
        end

        boards[Plan::ROOT_KEY]
      end

      # Re-resolved through Boards::AdminBuilder::ExistingBoards rather than
      # `Board.find`: the id came off a form post, and the scope is what keeps
      # "link an existing board" from becoming "point a published admin set at
      # any board in the database".
      def resolve_linked_boards!
        pages.select { |page| Plan.linked?(page) }.to_h do |page|
          id = page[:existing_board_id]
          board = ExistingBoards.find(id)
          raise BuildError, "page #{page[:key].inspect} links to board #{id}, which isn't a linkable board" if board.nil?

          pin_as_main_board!(board)
          [page[:key], board]
        end
      end

      # `Board#check_is_sub_board` is a before_save that flips `sub_board` on as
      # soon as `parent_boards` finds anything pointing at the board. Linking
      # gives this board a new parent, so the NEXT save for any unrelated reason
      # would quietly demote a published board out of `main_boards` — and out of
      # `Boards::AdminSearch.base_scope`, which is how it disappears from admin
      # board search without anyone touching it.
      #
      # `builder_root` is the existing flag for exactly this ("pin it as a main
      # board regardless of who links to it"). It keys off `builder_root`, not
      # `admin_builder`, so setting it does NOT pull the board into any build's
      # `set_boards`. Idempotent, and the only write this build makes to a board
      # it does not own.
      def pin_as_main_board!(board)
        settings = board.settings || {}
        return if settings["builder_root"] == true

        board.update!(settings: settings.merge("builder_root" => true))
      end

      def new_board(page)
        root = Plan.root?(page)
        columns = page[:columns].to_i

        board = Board.new(
          name: page[:name],
          user: admin,
          parent: admin,
          # Deliberately NOT `predefined`. `Board.public_boards` keys on it, and
          # a builder board is authored for printables and direct /pb/ sharing,
          # not for the public catalogue — dropping a whole set (root plus every
          # folder page) into the library each time an admin tried a build is
          # what that flag would do. Admin::BoardPrintablesController reaches
          # these through AdminBoardBuild.builder_boards instead.
          predefined: false,
          # Published on creation, root and pages alike. `Board#viewable_by?`
          # gates each board on its OWN flag, so a half-published set 404s every
          # folder tile — the set is only ever published as a unit (the same
          # rule Admin::BoardBuildsController#publish enforces).
          published: true,
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
          # Catalogue metadata belongs to the root alone — it describes the set,
          # and a folder page carrying the same description and tags is noise in
          # every list that shows them.
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

        # A picture the admin picked on the review screen instead of the
        # library's own. Pinned per TILE, not on the Image — every other board
        # using this word keeps whatever the library resolves for it.
        picked = picked_doc_urls[Boards::ImageResolver.normalize(tile[:label].to_s)]
        attrs[:display_image_url] = picked if picked.present?

        display_label = tile[:display_label].to_s
        attrs[:display_label] = display_label if display_label.present?

        board_image.update!(attrs) if attrs.any?
      end

      # A tile becomes a folder when its predictive_board_id points at another
      # board — the same one-line link Boards::BoardTreeBuilder makes.
      #
      # Folder tiles navigate silently. A tile that opens a page is a door, not
      # a word: speaking "Food" out loud on the way to the food page puts a word
      # into the utterance the communicator didn't choose to say. `mute_name` is
      # the same display-only flag BuildBoardSetJob defaults on the communicator
      # builder's dynamic tiles and NavRowSync sets on its nav tiles — set it
      # here rather than after the fact so a built set is right on first render.
      # No self-tile exception: nothing in an admin-built set is a you-are-here
      # anchor, so the "back to home" tile is a door like any other.
      def link_pages!(boards, tiles_by_key)
        owned_pages.each do |page|
          page[:tiles].each_with_index do |tile, index|
            target = tile[:links_to].presence
            next if target.nil?

            child = boards[target]
            raise BuildError, "tile #{tile[:label].inspect} links to unknown page #{target.inspect}" if child.nil?

            board_image = tiles_by_key[page[:key]][index]
            board_image.update!(
              predictive_board_id: child.id,
              data: (board_image.data || {}).merge("mute_name" => true),
            )
          end
        end
      end

      # Reading order: left to right, top to bottom, in the order the words were
      # authored. apply_layout! sorts by [y, x] and rewrites every tile's
      # position, so the layout — not creation order — decides the final order.
      #
      # The one departure from authored order is BackTileAlignment, which swaps
      # a page's back tile into the cell its parent's folder tile occupies. It
      # returns a cell index per tile, so the same `% columns` / `/ columns`
      # math still produces the grid.
      def cell_indexes
        @cell_indexes ||= BackTileAlignment.cell_indexes(pages)
      end

      def apply_reading_order!(board, board_images, page)
        columns = page[:columns].to_i
        cells = cell_indexes[page[:key]] || []
        layout = board_images.each_with_index.map do |board_image, index|
          cell = cells[index] || index
          {
            "i" => board_image.id.to_s,
            "x" => cell % columns,
            "y" => cell / columns,
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

      # Images behind the tiles the admin marked "regenerate with AI" on the
      # review screen. `resolved` is keyed by the resolver's normalized label,
      # which is exactly the form the marks were stored in.
      #
      # Minus the blanks: a label with no art is already queued by
      # queue_missing_art!, and generating it twice is two API calls for one
      # picture.
      # Minus the picks too: a tile whose picture the admin chose by hand must
      # not have AI art generated over it, and unpin_regenerated_tiles! would
      # drop the pin that carries the choice.
      def regenerate_image_ids(blank_image_ids)
        (build.regenerate_labels - picked_doc_urls.keys)
          .filter_map { |label| resolved[label]&.id }
          .uniq - blank_image_ids
      end

      # Label => the URL of the Doc the admin pinned to that tile. Resolved in
      # one query for the whole set, and a doc that has since been deleted just
      # drops out — the tile falls back to the library's own art rather than
      # failing the build over a picture.
      #
      # Prefers the 288px tile variant, but only when it is ALREADY processed:
      # materializing it here would run an inline download+transform per tile
      # inside the build transaction. The full-resolution original renders fine
      # in the meantime.
      def picked_doc_urls
        @picked_doc_urls ||= begin
          picks = build.display_doc_ids
          docs = picks.any? ? Doc.where(id: picks.values.uniq).index_by(&:id) : {}
          picks.filter_map do |label, doc_id|
            doc = docs[doc_id]
            next if doc.nil?

            url = doc.tile_variant_processed? ? doc.tile_url : doc.display_url
            [label, url] if url.present?
          end.to_h
        end
      end

      # A marked tile was built with the library's art, so BoardImage#set_defaults
      # seeded `display_image_url` from the image's src_url — pinning the tile to
      # the picture we are about to replace. Release the pin so the tile falls
      # through to the image's own current doc once generation lands.
      #
      # It must be NIL, never "": a blank display_image_url is the marker for
      # "this tile has no picture" and would print the label with no art at all.
      #
      # Covers the whole set, not just the root. GenerateImagesJob only re-points
      # board_images on the single board_id it is handed, so a repeated word on a
      # child page would otherwise keep the old art forever.
      def unpin_regenerated_tiles!(image_ids)
        return if image_ids.empty?

        BoardImage.where(board_id: @built_boards.values.map(&:id), image_id: image_ids)
                  .update_all(display_image_url: nil)
      end

      def art_report(root, blank_image_ids, regenerate_ids = [])
        total = Plan.labels(pages).size
        missing = resolved.select { |_, image| blank_image_ids.include?(image.id) }.keys

        {
          "tile_count" => total,
          "with_art" => total - missing.size,
          "coverage_pct" => total.zero? ? 0 : (((total - missing.size) / total.to_f) * 100).round,
          "missing_labels" => missing,
          "queued_image_ids" => blank_image_ids,
          # Tiles the admin marked for AI art despite the library having a
          # picture for them — `show` reports these separately from the blanks.
          "regenerated_labels" => resolved.select { |_, image| regenerate_ids.include?(image.id) }.keys,
          "regenerated_image_ids" => regenerate_ids,
          # Tiles whose picture the admin picked by hand on the review screen.
          "picked_labels" => picked_doc_urls.keys,
          "slug" => root.slug,
          # Boards this set POINTS AT but does not own. Kept out of "boards" on
          # purpose: `set_boards` reads that key, and publish/unpublish/destroy
          # iterate it. Recorded so `show` can list the whole set honestly and
          # `rake admin_board_builds:orphans` doesn't mistake a linked board for
          # a stranded one.
          "linked_boards" => @linked_boards.transform_values(&:id),
          # key => board id, so `show` can list every page of the set and
          # publish can cascade over it without re-walking the link graph.
          # Also written at claim time (see #create_and_claim!) — this is the
          # same value, re-stated as part of the complete report.
          "boards" => built_board_ids,
        }
      end

      # Queued after commit: Sidekiq can otherwise pick the job up before the
      # rows it references exist.
      def queue_missing_art!(root, image_ids)
        ArtQueue.call(board: root, image_ids: image_ids, topic: build.topic)
      end

      # Separate call from the blanks because of `replace_current`: these images
      # already carry a library doc, and the generated one has to become the
      # current doc or the build would show the symbol the admin just rejected.
      def queue_regenerated_art!(root, image_ids)
        ArtQueue.call(board: root, image_ids: image_ids, topic: build.topic, replace_current: true)
      end
    end
  end
end
