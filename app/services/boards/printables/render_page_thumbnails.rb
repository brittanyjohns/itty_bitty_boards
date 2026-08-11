# Screenshots board pages into data URIs the listing slides can lay out.
#
# The pipeline gets its page thumbnails by rasterizing the finished PDF with
# poppler's pdftoppm. We can't — poppler and ImageMagick aren't in the deploy
# image — but we don't need to: a board page is HTML before it is ever a PDF, so
# Grover can screenshot the same markup CollectPages prints from. Same template,
# same assigns, same QR target, so a thumbnail is the page a buyer receives
# rather than an approximation of it.
#
# Colour only. Low-ink pages are pixel duplicates at thumbnail size, and a grid
# showing each board twice reads as padding rather than as more value; they're
# sold in the caption instead (see ContentTilePlan).
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

      Thumbnail = Struct.new(:board_id, :data_uri, :landscape, keyword_init: true)

      def initialize(boards:)
        @boards = Array(boards)
      end

      # => { board_id => Thumbnail }, missing any board whose render failed.
      def call
        boards.each_with_object({}) do |board, out|
          thumbnail = render(board)
          out[board.id] = thumbnail if thumbnail
        end
      end

      private

      attr_reader :boards

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

        png = trim_trailing_blank(screenshot(html, data[:landscape]))

        Thumbnail.new(
          board_id: board.id,
          data_uri: "data:image/png;base64,#{Base64.strict_encode64(png)}",
          landscape: data[:landscape],
        )
      rescue StandardError => e
        Rails.logger.warn(
          "[RenderPageThumbnails] board=#{board.id} skipped: #{e.class}: #{e.message}",
        )
        nil
      end

      # The same arguments CollectPages#render_page uses for a colour page. If
      # these drift, the gallery starts advertising a page the buyer won't get.
      def render_data_for(board)
        Boards::RenderAssetData.new(
          board: board,
          screen_size: "lg",
          hide_colors: false,
          hide_header: false,
          routes: Rails.application.routes.url_helpers,
          include_qr: true,
          qr_target_url: Qr.target_url_for(board),
        ).call
      end

      # layouts/pdf sizes .page to 100vw/100vh, so a viewport screenshot is
      # exactly one page — no clip maths, and that layout stays untouched.
      def screenshot(html, landscape)
        viewport = (landscape ? LANDSCAPE : PORTRAIT).merge(device_scale_factor: SCALE)

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
      def trim_trailing_blank(png)
        image = ChunkyPNG::Image.from_blob(png)
        background = image[image.width - 2, image.height - 2]

        last_content_row = (image.height - 1).downto(0).find do |y|
          (0...image.width).step(TRIM_SAMPLE_STRIDE).any? { |x| image[x, y] != background }
        end
        return png if last_content_row.nil?

        # +1 turns the last content ROW INDEX into a height, so the margin below
        # it is exactly TRIM_MARGIN_PX.
        height = [last_content_row + 1 + TRIM_MARGIN_PX, image.height].min
        return png if height >= image.height

        # good_compression, not best: best buys ~4% for 4x the CPU, and this
        # runs once per board on a job that already renders a browser page.
        image.crop(0, 0, image.width, height).to_blob(:good_compression)
      rescue StandardError => e
        # An untrimmed thumbnail is a worse-looking slide, not a broken one.
        Rails.logger.warn("[RenderPageThumbnails] trim failed: #{e.class}: #{e.message}")
        png
      end
    end
  end
end
