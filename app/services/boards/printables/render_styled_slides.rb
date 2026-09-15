# Renders the STYLED gallery slides for a printable: 4:3 marketing art in the
# warm cream / soft pink / gentle green design, built from the printable's real
# page renders.
#
# The design started as image-model output, and it could only be copied, never
# used: the model redrew every symbol, invented QR codes and a /pb/ URL, and
# printed whatever counts it was told. Here the pages are the real renders
# (RenderPageThumbnails — the same markup the PDF prints from, QR included) and
# every number comes from Printables::GalleryFacts.
#
# Sits beside RenderListingImages rather than inside it: those ten square
# slides are Etsy's cap and the current publish path, and nothing here changes
# what a listing uploads.
#
# Grover work, so it belongs on Sidekiq, never a request thread.
module Boards
  module Printables
    class RenderStyledSlides
      # 4:3, the shape the design was drawn in. 1200 CSS px at a device scale of
      # 2 lands at 2400x1800. SCALE must be nested inside `viewport` — Grover
      # ignores it anywhere else (see RenderListingImages#render).
      CANVAS_W = 1200
      CANVAS_H = 900
      SCALE = 2

      # The hero's fanned row under the main page. Past six the cards are too
      # narrow to read as pages; what's-included is where the set is counted.
      FAN_PAGES = 6
      # What's included is a 3x3 grid at most; the rest is counted.
      GRID_PAGES = 9

      # A fixed tilt per card rather than a formula: a fan reads as a pile of
      # paper when the tilts alternate unevenly.
      FAN_ROTATIONS = [-6, 4, -3, 5, -4, 3, -5].freeze

      TEMPLATES = {
        BoardPrintable::IMAGE_STYLED_HERO => "hero",
        BoardPrintable::IMAGE_STYLED_WHATS_INCLUDED => "whats_included",
      }.freeze

      def initialize(printable:, variants: BoardPrintable::STYLED_IMAGE_VARIANTS)
        unknown = Array(variants) - BoardPrintable::STYLED_IMAGE_VARIANTS
        raise ArgumentError, "Unknown styled slide variants: #{unknown.join(", ")}" if unknown.any?

        @printable = printable
        @variants = BoardPrintable::STYLED_IMAGE_VARIANTS & Array(variants)
      end

      # => the variants rendered
      def call
        metadata = {
          spec_version: BoardPrintable::STYLED_SPEC_VERSION,
          facts_digest: facts.digest,
        }

        variants.each do |variant|
          bytes = render(TEMPLATES.fetch(variant), assigns: assigns_for(variant))
          printable.attach_image!(bytes: bytes, variant: variant, metadata: metadata)
        end

        variants
      end

      private

      attr_reader :printable, :variants

      def facts = @facts ||= ::Printables::GalleryFacts.new(printable)

      def board = printable.board

      def boards = @boards ||= printable.ordered_boards

      def root = boards.find { |b| b.id == board.id } || boards.first

      def assigns_for(variant)
        case variant
        when BoardPrintable::IMAGE_STYLED_HERO then hero_assigns
        when BoardPrintable::IMAGE_STYLED_WHATS_INCLUDED then whats_included_assigns
        end
      end

      def shared_assigns
        {
          logo: BrandAssets.logo_data_uri,
          accents: ::Printables::StyledSlideCopy.accents,
        }
      end

      # ── Page renders ──────────────────────────────────────────────────────
      #
      # Three passes, each memoized and only paid for by a slide that uses it:
      #
      #   hero    — colour, header SHOWN, root + the fan. The header carries the
      #             printed logo, title and QR: the hero's claim is the sheet.
      #   low_ink — the root, header shown, printed pale. Only when the listing
      #             actually ships a low-ink file.
      #   grid    — colour, header HIDDEN, for what's included, where a pill
      #             title replaces the header at a readable size.

      def hero_thumbnails
        @hero_thumbnails ||= RenderPageThumbnails.new(boards: boards.first(FAN_PAGES + 1)).call
      end

      def low_ink_thumbnail
        return @low_ink_thumbnail if defined?(@low_ink_thumbnail)

        @low_ink_thumbnail = facts.low_ink? && root &&
          RenderPageThumbnails.new(boards: [root], hide_colors: true).call[root.id]
      end

      def grid_plan
        @grid_plan ||= ContentTilePlan.build(boards: boards, max_tiles: GRID_PAGES)
      end

      def grid_thumbnails
        @grid_thumbnails ||= RenderPageThumbnails.new(boards: grid_plan.boards, hide_header: true).call
      end

      def page_for(thumbnail, label: nil)
        return nil unless thumbnail

        { data_uri: thumbnail.data_uri, width: thumbnail.width, height: thumbnail.height, label: label }
      end

      # ── Slides ────────────────────────────────────────────────────────────

      def hero_assigns
        others = boards.reject { |b| b == root }.first(FAN_PAGES)
        fan = others.filter_map { |b| page_for(hero_thumbnails[b.id]) }
        fan << page_for(low_ink_thumbnail) if low_ink_thumbnail
        fan = fan.each_with_index.map { |page, i| page.merge(rotation: FAN_ROTATIONS[i % FAN_ROTATIONS.size]) }

        shared_assigns.merge(
          headline: ::Printables::StyledSlideCopy.hero_headline(
            board_title: Boards::AssetRendering.board_title_for(board),
            board_count: facts.board_count,
          ),
          features: ::Printables::StyledSlideCopy.hero_features(facts),
          badges: ::Printables::StyledSlideCopy.hero_badges(facts),
          set_accent: ::Printables::StyledSlideCopy.hero_set_accent(facts),
          main_page: root && page_for(hero_thumbnails[root.id]),
          fan_pages: fan,
        )
      end

      def whats_included_assigns
        tiles = grid_plan.tiles.filter_map do |tile|
          page_for(grid_thumbnails[tile.board_id], label: tile.label)
        end

        shared_assigns.merge(
          title: ::Printables::StyledSlideCopy.whats_included_title,
          features: ::Printables::StyledSlideCopy.whats_included_features(facts),
          badges: ::Printables::StyledSlideCopy.whats_included_badges(facts),
          corner_accent: ::Printables::StyledSlideCopy.whats_included_corner_accent(facts),
          footer_accent: ::Printables::StyledSlideCopy.whats_included_footer_accent(
            facts, root_title: root && Boards::AssetRendering.board_title_for(root),
          ),
          tiles: tiles,
          columns: grid_columns(tiles.size),
          rows: [(tiles.size / grid_columns(tiles.size).to_f).ceil, 1].max,
          overflow_note: grid_plan.overflow_note,
        )
      end

      def grid_columns(count)
        return 1 if count <= 1
        return 2 if count <= 4

        3
      end

      def render(template, assigns:)
        html = ApplicationController.render(
          template: "api/board_printables/styled/#{template}",
          layout: "listing_image_styled",
          assigns: assigns,
          formats: [:html],
        )

        Grover.new(
          html,
          viewport: { width: CANVAS_W, height: CANVAS_H, device_scale_factor: SCALE },
          print_background: true,
        ).to_png
      end
    end
  end
end
