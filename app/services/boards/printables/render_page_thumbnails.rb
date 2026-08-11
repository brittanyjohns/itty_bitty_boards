# Screenshots board pages into data URIs the listing slides can lay out.
#
# The pipeline gets its page thumbnails by rasterizing the finished PDF with
# poppler's pdftoppm. We can't — poppler and ImageMagick aren't in the deploy
# image — but we don't need to: a board page is HTML before it is ever a PDF, so
# Grover can screenshot the same markup CollectPages prints from. Same template,
# same assigns, same QR target, so a thumbnail is the page a buyer receives
# rather than an approximation of it.
#
# Renders whatever page variant it is asked for. The gallery uses three passes:
# colour with the page header for the hero (the printed QR lives inside that
# header, and the hero's claim is that the sheet itself carries the code), and
# colour + low-ink without it for the two what's-included grids, where the header
# only repeats the slide's own title band and eats a third of a small tile.
module Boards
  module Printables
    class RenderPageThumbnails
      # Letter at 96 CSS px/in, matching CollectPages' viewports exactly.
      PORTRAIT = { width: 612, height: 792 }.freeze
      LANDSCAPE = { width: 792, height: 612 }.freeze

      # A thumbnail is rendered at ~2x its slot on a 1280px slide, which is what
      # the hero needs: there the page is nearly slide-width, so anything less
      # is visibly soft in the one image that competes in an Etsy search grid.
      SCALE = 2

      # Blank paper left below the board, in device pixels, once the trim has
      # found the last row of content. Roughly 6mm at SCALE 2 — enough that the
      # page still reads as a printed sheet with a margin rather than as art
      # cropped flush to its edge.
      TRIM_MARGIN_PX = 24

      # Rows are sampled rather than scanned pixel by pixel. A board tile is
      # never narrower than a few dozen pixels at this scale, so a stride of 4
      # cannot miss one, and it makes the scan ~4x cheaper.
      TRIM_SAMPLE_STRIDE = 4

      # width/height are the thumbnail's real pixel dimensions AFTER the trim.
      # The slides need them: a listing card sized by a percentage max-height
      # can't resolve against a card whose own height is indefinite, so the
      # templates set an explicit aspect-ratio from these instead. They are
      # never nil — an untrimmed or undecodable PNG falls back to the viewport.
      Thumbnail = Struct.new(:board_id, :data_uri, :landscape, :width, :height, keyword_init: true)

      def initialize(boards:, hide_colors: false, hide_header: false)
        @boards = Array(boards)
        @hide_colors = hide_colors
        @hide_header = hide_header
      end

      # => { board_id => Thumbnail }, missing any board whose render failed.
      def call
        boards.each_with_object({}) do |board, out|
          thumbnail = render(board)
          out[board.id] = thumbnail if thumbnail
        end
      end

      private

      attr_reader :boards, :hide_colors, :hide_header

      # A thumbnail is decoration on a marketing image, not part of the product.
      # One board failing to render must cost that tile and nothing else — the
      # gallery is still shippable with a gap, and the PDF the buyer actually
      # receives is untouched by anything here.
      def render(board)
        data = render_data_for(board)
        html = ApplicationController.render(
          template: "api/boards/print",
          layout: "pdf",
          assigns: data,
          formats: [:html],
        )

        png, width, height = trim_trailing_blank(screenshot(html, data[:landscape]))

        Thumbnail.new(
          board_id: board.id,
          data_uri: "data:image/png;base64,#{Base64.strict_encode64(png)}",
          landscape: data[:landscape],
          width: width || viewport_for(data[:landscape])[:width] * SCALE,
          height: height || viewport_for(data[:landscape])[:height] * SCALE,
        )
      rescue StandardError => e
        Rails.logger.warn(
          "[RenderPageThumbnails] board=#{board.id} skipped: #{e.class}: #{e.message}",
        )
        nil
      end

      # The same arguments CollectPages#render_page uses. hide_colors picks the
      # low-ink page the buyer also receives; if these drift any further, the
      # gallery starts advertising a page that isn't in the download.
      def render_data_for(board)
        Boards::RenderAssetData.new(
          board: board,
          screen_size: "lg",
          hide_colors: hide_colors,
          hide_header: hide_header,
          routes: Rails.application.routes.url_helpers,
          include_qr: true,
          qr_target_url: Qr.target_url_for(board),
        ).call
      end

      def viewport_for(landscape) = landscape ? LANDSCAPE : PORTRAIT

      # layouts/pdf sizes .page to 100vw/100vh, so a viewport screenshot is
      # exactly one page — no clip maths, and that layout stays untouched.
      def screenshot(html, landscape)
        viewport = viewport_for(landscape).merge(device_scale_factor: SCALE)

        Grover.new(
          html,
          viewport: viewport,
          full_page: false,
          print_background: true,
        ).to_png
      end

      # Cuts the blank paper off the bottom of a rendered page.
      #
      # How much of a Letter sheet a board fills depends entirely on its shape:
      # a 12x3 grid is wide and short and leaves over half the page empty, and
      # on a listing slide that reads as a broken image rather than as a margin.
      #
      # Measured, not calculated. The obvious approach — take the header height
      # and board height RenderAssetData already computes — does not work:
      # the header renders ~24mm against the 30mm it reserves, and a tall board
      # is clamped by .board-sizer's max-height so its computed height overstates
      # what is actually drawn. Both errors run in the direction that would slice
      # tiles off. Scanning up from the bottom for the last row that differs from
      # the page background is exact for every board shape, and costs ~1s.
      #
      # => [png, width, height]. The dimensions come back because the slides
      # size the page card from them; nil for either means "couldn't measure it,
      # use the viewport" rather than "the image has no size".
      def trim_trailing_blank(png)
        image = ChunkyPNG::Image.from_blob(png)
        background = image[image.width - 2, image.height - 2]

        last_content_row = (image.height - 1).downto(0).find do |y|
          (0...image.width).step(TRIM_SAMPLE_STRIDE).any? { |x| image[x, y] != background }
        end
        return [png, image.width, image.height] if last_content_row.nil?

        # +1 turns the last content ROW INDEX into a height, so the margin below
        # it is exactly TRIM_MARGIN_PX.
        height = [last_content_row + 1 + TRIM_MARGIN_PX, image.height].min
        return [png, image.width, image.height] if height >= image.height

        # good_compression, not best: best buys ~4% for 4x the CPU, and this
        # runs once per board on a job that already renders a browser page.
        [image.crop(0, 0, image.width, height).to_blob(:good_compression), image.width, height]
      rescue StandardError => e
        # An untrimmed thumbnail is a worse-looking slide, not a broken one.
        Rails.logger.warn("[RenderPageThumbnails] trim failed: #{e.class}: #{e.message}")
        [png, nil, nil]
      end
    end
  end
end
