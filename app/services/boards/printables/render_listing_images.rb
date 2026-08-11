# Renders the six marketplace gallery slides for a printable: the hero, the
# board on a tablet, what's included in colour, the same in low-ink, how it
# works, and about.
#
# Etsy will create a listing with no photos but won't let it go live without
# one, so these are the minimum a draft needs to be finishable — but they're
# also the listing's whole shop window, and the first is the thumbnail competing
# in a search grid. They are purpose-built square marketing art, NOT the printed
# page scaled down onto a mat, which is what this rendered before: honest, and
# invisible next to the competition.
#
# Ported from the speakanyway-printables pipeline's step 11. That repo still
# owns the richer gallery — lifestyle mockups composited into photographed room
# scenes (its steps 13/14) — which needs a calibrated scene library and a
# homography solve, and is a different project.
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
        printable.attach_image!(bytes: render("hero", assigns: hero_assigns), variant: BoardPrintable::IMAGE_HERO)
        printable.attach_image!(bytes: render("on_a_device", assigns: on_a_device_assigns), variant: BoardPrintable::IMAGE_ON_A_DEVICE)
        printable.attach_image!(bytes: render("whats_included", assigns: whats_included_assigns(low_ink: false)), variant: BoardPrintable::IMAGE_WHATS_INCLUDED)
        printable.attach_image!(bytes: render("whats_included", assigns: whats_included_assigns(low_ink: true)), variant: BoardPrintable::IMAGE_WHATS_INCLUDED_LOW_INK)
        printable.attach_image!(bytes: render("how_it_works", assigns: shared_assigns), variant: BoardPrintable::IMAGE_HOW_IT_WORKS)
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
        @plan ||= ContentTilePlan.build(boards: ordered_boards)
      end

      # board_ids is in tree order (root first) and a `where` loses it, so the
      # records are put back into it.
      def ordered_boards
        ids = printable.board_ids.to_a.presence || [board.id]
        by_id = Board.where(id: ids).index_by(&:id)
        ids.filter_map { |id| by_id[id] }
      end

      # The hero shows at most three pages. It is a shop window, not an
      # inventory: past three the pages are too small to tell apart, and the
      # what's-included slide is where the full set is counted.
      HERO_TILES = 3

      # Three passes over the boards, each memoized, because the slides need
      # genuinely different pages — not the same pixels twice:
      #
      #   hero  — colour, page header SHOWN. The printed QR lives inside that
      #           header, and the hero's whole claim is that the sheet itself
      #           carries the code.
      #   grid  — colour and low-ink, header HIDDEN. At a sixth of the slide the
      #           header is just the slide's own title band again, and hiding it
      #           gives the board the whole tile.
      #
      # Budget: min(boards, 3) + min(boards, 8) * 2 renders, plus six slides and
      # the one device screen. That is why this runs on Sidekiq and never on a
      # request thread.
      def hero_thumbnails
        @hero_thumbnails ||= RenderPageThumbnails.new(
          boards: plan.boards.first(HERO_TILES),
        ).call
      end

      def grid_thumbnails(low_ink:)
        @grid_thumbnails ||= {}
        @grid_thumbnails[low_ink] ||= RenderPageThumbnails.new(
          boards: plan.boards,
          hide_colors: low_ink,
          hide_header: true,
        ).call
      end

      # Tiles that actually have a rendered thumbnail behind them — a board
      # whose page render failed is dropped rather than rendering an empty card.
      def tiles_from(thumbnails)
        plan.tiles.filter_map do |tile|
          thumb = thumbnails[tile.board_id]
          next unless thumb

          {
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
          qr_data_url: Qr.data_url_for(Qr.target_url_for(board)),
          palette_css: Palette.for(board).css_vars,
        }
      end

      def hero_assigns
        shared_assigns.merge(
          title: Boards::AssetRendering.board_title_for(board),
          headline: ::Printables::SlideCopy.hero_headline(board_count: board_count, topic: printable.topic),
          background: BrandAssets.scene_data_uri_for(board),
          thumbnails: tiles_from(hero_thumbnails).first(HERO_TILES),
        )
      end

      def whats_included_assigns(low_ink:)
        shared_assigns.merge(
          low_ink: low_ink,
          tiles: tiles_from(grid_thumbnails(low_ink: low_ink)),
          columns: plan.columns,
          rows: plan.rows,
          tile_max_px: plan.tile_max_px,
          overflow_note: plan.overflow_note,
          items: included_items,
        )
      end

      # The tablet shows the board inside the APP's chrome, not a bare printed
      # page: a Letter sheet warped onto the glass reads as a photograph of
      # paper taped to a screen, and carries nothing that says the thing on it
      # talks. RenderDeviceScreen wraps the root board's already-rendered
      # header-less thumbnail in that chrome — one extra Grover render for the
      # slide whose whole job is "this also opens on the tablet you own".
      def on_a_device_assigns
        scene = TabletScene.for(board)
        title = Boards::AssetRendering.board_title_for(board)

        shared_assigns.merge(
          title: title,
          scene: scene,
          scene_data_uri: scene.data_uri,
          board_data_uri: RenderDeviceScreen.new(
            title: title,
            thumbnail: grid_thumbnails(low_ink: false)[board.id],
          ).call,
        )
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
        ::Printables::IncludedItems.all(board_count: board_count, page_count: printable.page_count)
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
