# Renders the four marketplace gallery slides for a printable: the hero, what's
# included, how it works, and about.
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
        printable.attach_image!(bytes: render("whats_included", assigns: whats_included_assigns), variant: BoardPrintable::IMAGE_WHATS_INCLUDED)
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

      # Rendered ONCE and shared by the hero and the what's-included grid. Eight
      # board pages is eight Grover renders; doing it per slide would double the
      # most expensive part of the job for two copies of the same pixels.
      def thumbnails
        @thumbnails ||= RenderPageThumbnails.new(boards: plan.boards).call
      end

      # Tiles that actually have a rendered thumbnail behind them — a board
      # whose page render failed is dropped rather than rendering an empty card.
      def tiles
        @tiles ||= plan.tiles.filter_map do |tile|
          thumb = thumbnails[tile.board_id]
          next unless thumb

          { label: tile.label, data_uri: thumb.data_uri, landscape: thumb.landscape }
        end
      end

      def shared_assigns
        {
          logo: BrandAssets.logo_data_uri,
          qr_data_url: Qr.data_url_for(Qr.target_url_for(board)),
        }
      end

      # The hero shows at most three pages. It is a shop window, not an
      # inventory: past three the pages are too small to tell apart, and the
      # what's-included slide is where the full set is counted.
      HERO_TILES = 3

      def hero_assigns
        shared_assigns.merge(
          title: Boards::AssetRendering.board_title_for(board),
          headline: ::Printables::SlideCopy.hero_headline(board_count: board_count, topic: printable.topic),
          background: BrandAssets.scene_data_uri_for(board),
          thumbnails: tiles.first(HERO_TILES),
        )
      end

      def whats_included_assigns
        shared_assigns.merge(
          tiles: tiles,
          columns: plan.columns,
          overflow_note: plan.overflow_note,
          items: included_items,
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
