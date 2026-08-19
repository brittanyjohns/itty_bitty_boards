# Renders the ten marketplace gallery slides for a printable — BoardPrintable::
# LISTING_IMAGE_ORDER is the list, and the order in which Etsy ranks them.
#
# Etsy will create a listing with no photos but won't let it go live without
# one, so these are the minimum a draft needs to be finishable — but they're
# also the listing's whole shop window, and the first is the thumbnail competing
# in a search grid. They are purpose-built square marketing art, NOT the printed
# page scaled down onto a mat, which is what this rendered before: honest, and
# invisible next to the competition.
#
# Four of the ten are photoreal MOCKUPS — two tablets and two printed sheets,
# each a real render warped onto a calibrated placeholder in a photographed room
# (MockupScene, TabletScene, PaperScene, Homography). Ported from the
# speakanyway-printables pipeline's steps 11/13/14, whose scene library and
# hand-clicked quads these reuse verbatim.
#
# Grover work, so it belongs on Sidekiq, never a request thread.
module Boards
  module Printables
    class RenderListingImages
      # Square, because Etsy frames listing photos square. 1280 CSS px at a
      # device scale of 2 lands at 2560 — over Etsy's 2000px recommendation, and
      # the same geometry the pipeline's slides use.
      #
      # SCALE must be read from inside `viewport`; Grover ignores it anywhere
      # else. See the render_png comment.
      CANVAS_PX = 1280
      SCALE = 2

      def initialize(printable:)
        @printable = printable
      end

      # => BoardPrintable::LISTING_IMAGE_ORDER
      def call
        printable.attach_image!(bytes: render("mockup", assigns: paper_assigns(0)), variant: BoardPrintable::IMAGE_ON_PAPER)
        printable.attach_image!(bytes: render("hero", assigns: hero_assigns), variant: BoardPrintable::IMAGE_HERO)
        printable.attach_image!(bytes: render("mockup", assigns: device_assigns(0)), variant: BoardPrintable::IMAGE_ON_A_DEVICE)
        printable.attach_image!(bytes: render("flip_book", assigns: flip_book_assigns), variant: BoardPrintable::IMAGE_FLIP_BOOK)
        printable.attach_image!(bytes: render("whats_included", assigns: whats_included_assigns), variant: BoardPrintable::IMAGE_WHATS_INCLUDED)
        printable.attach_image!(bytes: render("mockup", assigns: paper_assigns(1)), variant: BoardPrintable::IMAGE_ON_PAPER_ALT)
        printable.attach_image!(bytes: render("assemble", assigns: shared_assigns), variant: BoardPrintable::IMAGE_ASSEMBLE)
        printable.attach_image!(bytes: render("mockup", assigns: device_assigns(1)), variant: BoardPrintable::IMAGE_ON_A_DEVICE_ALT)
        printable.attach_image!(bytes: render("page_index", assigns: page_index_assigns), variant: BoardPrintable::IMAGE_PAGE_INDEX)
        printable.attach_image!(bytes: render("about", assigns: about_assigns), variant: BoardPrintable::IMAGE_ABOUT)

        # Last, and only once every slide is attached: a render that raises
        # part-way leaves the old gallery intact rather than emptying it.
        printable.purge_legacy_listing_images!

        BoardPrintable::LISTING_IMAGE_ORDER
      end

      private

      attr_reader :printable

      def board = printable.board

      def board_count = [printable.board_ids.to_a.size, 1].max

      def set? = board_count > 1

      # Planned before anything is rendered, so Grover is only paid for tiles
      # that will actually be shown.
      def plan
        @plan ||= ContentTilePlan.build(boards: printable.ordered_boards)
      end

      # The hero shows at most five pages. It is a shop window, not an
      # inventory: past five each card is under 290px on the 960px stage and a
      # board page at that size is a coloured smudge, and the what's-included
      # slide is where the full set is counted. HeroFan owns that limit — this
      # constant must not exceed HeroFan::MAX_CARDS, which is asserted in the
      # spec rather than left to whoever raises it next.
      HERO_TILES = 5

      # Three passes over the boards, each memoized, because the slides need
      # genuinely different pages — not the same pixels twice:
      #
      #   hero      — colour, page header SHOWN. The printed QR lives inside
      #               that header, and both the hero and the PAPER mockups
      #               depend on the sheet visibly carrying the code.
      #   grid      — colour, header HIDDEN. At a sixth of the slide the header
      #               is just the slide's own title band again, and hiding it
      #               gives the board the whole tile. Also what the tablets warp
      #               onto the glass, inside the app shell.
      #   low_ink   — ONE page, header hidden, printed pale. The proof card on
      #               the what's-included slide.
      #
      # Budget: min(boards, HERO_TILES) + min(boards, 8) + 1 renders, plus the
      # ten slides and two device screens. The low-ink pass used to cover every
      # planned board for a whole second slide of its own; a single inset page
      # makes the same claim for one render instead of eight.
      #
      # That is still why this runs on Sidekiq and never on a request thread.
      def hero_thumbnails
        @hero_thumbnails ||= RenderPageThumbnails.new(
          boards: plan.boards.first(HERO_TILES),
        ).call
      end

      def grid_thumbnails
        @grid_thumbnails ||= RenderPageThumbnails.new(
          boards: plan.boards,
          hide_colors: false,
          hide_header: true,
        ).call
      end

      def low_ink_thumbnail
        return @low_ink_thumbnail if defined?(@low_ink_thumbnail)

        root = plan.boards.first
        @low_ink_thumbnail = root && RenderPageThumbnails.new(
          boards: [root],
          hide_colors: true,
          hide_header: true,
        ).call[root.id]
      end

      # Tiles that actually have a rendered thumbnail behind them — a board
      # whose page render failed is dropped rather than rendering an empty card.
      def tiles_from(thumbnails)
        plan.tiles.filter_map do |tile|
          thumb = thumbnails[tile.board_id]
          next unless thumb

          {
            board_id: tile.board_id,
            label: tile.label,
            data_uri: thumb.data_uri,
            landscape: thumb.landscape,
            width: thumb.width,
            height: thumb.height,
          }
        end
      end

      def shared_assigns
        {
          logo: BrandAssets.logo_data_uri,
          qr_data_url: Qr.data_url_for(
            Qr.listing_target_url_for(board, content: "listing_image"),
            level: Qr::SCREEN_ECC,
          ),
          palette_css: Palette.for(board).css_vars,
        }
      end

      def hero_assigns
        tiles = hero_tiles

        shared_assigns.merge(
          title: Boards::AssetRendering.board_title_for(board),
          headline: ::Printables::SlideCopy.hero_headline(board_count: board_count, topic: printable.topic),
          background: BrandAssets.scene_data_uri_for(board),
          thumbnails: tiles,
          # Keyed off how many pages actually RENDERED, not board_count: a board
          # whose thumbnail failed is dropped by tiles_from, and a fan sized for
          # a card that isn't there leaves a hole in the pile.
          fan: tiles.size > 1 ? HeroFan.build(tiles.size) : nil,
          # The sticker counts the whole set, which is the honest number even
          # when the hero could only show five of them.
          count_badge: ::Printables::SlideCopy.hero_count_badge(board_count: board_count),
        )
      end

      # The ROOT board goes in the middle of the fan, because the middle card is
      # the one drawn in front and uncropped (`.hero-stage.fan` in
      # `layouts/listing_image.html.erb`). Board ids arrive in tree order, so
      # the root landed in the first slot — the rotated card at the BACK — and
      # the page a buyer actually saw in the search grid was whichever subboard
      # happened to be second: a keyboard page, or a mostly-empty fringe page.
      # The root is the densest, most recognisable page in the set and the one
      # the listing is named after; it is what the thumbnail has to show.
      def hero_tiles
        tiles = tiles_from(hero_thumbnails).first(HERO_TILES)
        return tiles if tiles.size < 2

        root_index = tiles.index { |tile| tile[:board_id] == board.id }
        center = tiles.size / 2
        return tiles if root_index.nil? || root_index == center

        tiles.dup.tap { |t| t.insert(center, t.delete_at(root_index)) }
      end

      # Reuses the hero's page thumbnails rather than taking a pass of its own —
      # the root plus the first pages its folder tiles open is exactly what
      # `hero_thumbnails` already rendered.
      #
      # FLIP_BOOK_CHILDREN is small on purpose: this slide is an argument, not
      # an inventory. Two children make the point that a folder tile opens a
      # page and the page comes back; a row of five just makes the cards small.
      FLIP_BOOK_CHILDREN = 2

      def flip_book_assigns
        tiles = tiles_from(hero_thumbnails)
        root = tiles.find { |tile| tile[:board_id] == board.id } || tiles.first
        children = tiles.reject { |tile| tile.equal?(root) }.first(FLIP_BOOK_CHILDREN)

        shared_assigns.merge(
          headline: ::Printables::SlideCopy.flip_book_headline(board_count: board_count),
          bullets: ::Printables::SlideCopy.flip_book_bullets(board_count: board_count),
          pages: [root].compact,
          linked: children,
        )
      end

      # Every board in the set, named, in tree order. Text only — no page
      # renders — so the cost is the one slide.
      #
      # Capped because a 25-row list at a legible size doesn't fit two columns
      # on a square slide; past the cap the remainder is counted rather than
      # silently dropped.
      PAGE_INDEX_ROWS = 24

      def page_index_assigns
        boards = printable.ordered_boards
        rows = boards.first(PAGE_INDEX_ROWS).map do |page|
          {label: Boards::AssetRendering.board_title_for(page), root: page.id == board.id}
        end
        remaining = boards.size - rows.size

        shared_assigns.merge(
          title: ::Printables::SlideCopy.page_index_title(board_count: board_count),
          headline: ::Printables::SlideCopy.page_index_headline(board_count: board_count),
          entries: rows,
          overflow: remaining.positive? ? "+ #{remaining} more #{'page'.pluralize(remaining)}" : nil,
        )
      end

      def whats_included_assigns
        proof = low_ink_thumbnail

        shared_assigns.merge(
          tiles: tiles_from(grid_thumbnails),
          columns: plan.columns,
          rows: plan.rows,
          tile_max_px: plan.tile_max_px,
          overflow_note: plan.overflow_note,
          items: included_items,
          # nil when the pale render failed — the slide drops the proof card
          # rather than showing an empty one, exactly as tiles_from drops a
          # board whose page didn't render.
          low_ink_proof: proof && {
            data_uri: proof.data_uri,
            width: proof.width,
            height: proof.height,
          },
        )
      end

      # ── The four mockup slides ────────────────────────────────────────────
      #
      # All four render `listing/mockup.html.erb`; they differ in which photo
      # they stage, which render they warp onto it, and their copy. Index 0 is
      # the first of a pair and index 1 the second, and the second is ALWAYS a
      # different scene and, where the printable has one, a different page —
      # otherwise the pair reads as one photograph duplicated.

      # The pages the mockups stage: the root, then the next in tree order. A
      # single-board printable falls back to the root for both, because the
      # slide's copy may vary but the slide itself must never disappear — see
      # BoardPrintable::LISTING_IMAGE_ORDER.
      def mockup_pages
        @mockup_pages ||= begin
          boards = plan.boards
          root = boards.find { |b| b.id == board.id } || boards.first
          [root, boards.reject { |b| b == root }.first || root].compact
        end
      end

      def mockup_page(index) = mockup_pages[index] || mockup_pages.first

      # The tablet shows the board inside the APP's chrome, not a bare printed
      # page: a Letter sheet warped onto the glass reads as a photograph of
      # paper taped to a screen, and carries nothing that says the thing on it
      # talks. RenderDeviceScreen wraps an already-rendered header-less
      # thumbnail in that chrome — one extra Grover render per tablet slide.
      def device_assigns(index)
        page = mockup_page(index)
        scene = tablet_scenes[index] || tablet_scenes.first
        title = page ? Boards::AssetRendering.board_title_for(page) : nil

        mockup_assigns(
          scene: scene,
          title: title,
          badge: index.zero? ? ::Printables::SlideCopy.on_a_device_badge : ::Printables::SlideCopy.on_a_device_alt_badge,
          headline: index.zero? ? ::Printables::SlideCopy.on_a_device_headline : ::Printables::SlideCopy.on_a_device_alt_headline(board_count: board_count),
          bullets: index.zero? ? ::Printables::SlideCopy.on_a_device_bullets : ::Printables::SlideCopy.on_a_device_alt_bullets(board_count: board_count),
          # The scene is handed over so the app shell is rendered at THIS
          # tablet's proportions — the homography will stretch whatever it is
          # given onto the glass, and a mismatched shell ships a squashed board.
          art_data_uri: page && scene && RenderDeviceScreen.new(
            title: title,
            thumbnail: grid_thumbnails[page.id],
            scene: scene,
          ).call,
        )
      end

      # The paper mockups warp the HEADER-SHOWN page — the sheet a buyer prints,
      # carrying its own logo, title and QR. That is the whole claim of the
      # slide, and it also keeps the QR honest for free: hero_thumbnails encode
      # the bare /pb/<slug> the printed page does, never the UTM-tagged listing
      # URL. Do not "improve" this by tagging it — see Boards::Printables::Qr.
      def paper_assigns(index)
        tile = paper_tiles[index] || paper_tiles.first
        scene = paper_scene_for(index, tile: tile)

        mockup_assigns(
          scene: scene,
          title: tile ? tile[:label].presence || board_title : board_title,
          badge: index.zero? ? ::Printables::SlideCopy.on_paper_badge : ::Printables::SlideCopy.on_paper_alt_badge,
          headline: index.zero? ? ::Printables::SlideCopy.on_paper_headline : ::Printables::SlideCopy.on_paper_alt_headline(board_count: board_count),
          bullets: index.zero? ? ::Printables::SlideCopy.on_paper_bullets : ::Printables::SlideCopy.on_paper_alt_bullets(board_count: board_count),
          art_data_uri: tile && tile[:data_uri],
        )
      end

      def mockup_assigns(scene:, title:, badge:, headline:, bullets:, art_data_uri:)
        shared_assigns.merge(
          title: title,
          scene: scene,
          scene_data_uri: scene&.data_uri,
          art_data_uri: art_data_uri,
          badge: badge,
          headline: headline,
          bullets: bullets,
        )
      end

      def board_title = Boards::AssetRendering.board_title_for(board)

      def tablet_scenes
        @tablet_scenes ||= TabletScene.pair_for(board)
      end

      # The root page first, then the next one — same pairing as mockup_pages,
      # but read off the hero pass because these slides need the header.
      def paper_tiles
        @paper_tiles ||= begin
          tiles = tiles_from(hero_thumbnails)
          root = tiles.find { |tile| tile[:board_id] == board.id } || tiles.first
          [root, tiles.reject { |tile| tile.equal?(root) }.first || root].compact
        end
      end

      # A scene whose placeholder is portrait cannot carry a landscape page: the
      # homography maps ANY rectangle onto the quad, so a mismatch does not fail
      # — it silently stretches, which a buyer reads as a distorted product. So
      # the pool is filtered by the page's own orientation first.
      #
      # The pair is drawn from the ROOT page's pool in one ranked pick, which is
      # what makes the two scenes distinct. A page of the other orientation —
      # rare, but a set can mix — takes its own pick from the other pool, and is
      # distinct by construction because the pools are disjoint.
      def paper_scene_for(index, tile:)
        landscape = tile.nil? || tile[:landscape] != false
        return paper_scenes[index] || paper_scenes.first if landscape == root_page_landscape

        PaperScene.for(board, landscape: landscape)
      end

      def paper_scenes
        @paper_scenes ||= PaperScene.pair_for(board, landscape: root_page_landscape)
      end

      def root_page_landscape
        return @root_page_landscape if defined?(@root_page_landscape)

        root = paper_tiles.first
        @root_page_landscape = root.nil? || root[:landscape] != false
      end

      def about_assigns
        shared_assigns.merge(founder_photo: BrandAssets.founder_photo_data_uri)
      end

      # Shared with the listing description so the slide and the text make the
      # same promises in the same words.
      #
      # Root-scoped: this class is itself inside `Boards::Printables`, so a bare
      # `Printables::` resolves to that and never reaches the top-level module.
      def included_items
        ::Printables::IncludedItems.all(board_count: board_count, page_count: printable.board_page_count)
      end

      def render(template, assigns:)
        html = ApplicationController.render(
          template: "api/board_printables/listing/#{template}",
          layout: "listing_image",
          assigns: assigns,
          formats: [:html],
        )

        # device_scale_factor MUST be nested inside viewport — Grover only reads
        # it there. A top-level one is accepted silently and dropped, which is
        # how this shipped 816px images for months.
        Grover.new(
          html,
          viewport: { width: CANVAS_PX, height: CANVAS_PX, device_scale_factor: SCALE },
          print_background: true,
        ).to_png
      end
    end
  end
end
