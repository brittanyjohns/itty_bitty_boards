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

      # A thumbnail is rendered at ~2x its slot on a 1280px slide, which is
      # enough to stay crisp at 2560px output without carrying a full-page
      # retina PNG into the HTML.
      SCALE = 2

      # JPEG, not PNG. Eight full board pages base64'd into one document is
      # megabytes of HTML string, and Grover holds the whole thing in memory
      # through the render. Board art is dense and photographic enough that q82
      # is invisible at tile size.
      QUALITY = 82

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

        Thumbnail.new(
          board_id: board.id,
          data_uri: "data:image/jpeg;base64,#{Base64.strict_encode64(screenshot(html, data[:landscape]))}",
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
          quality: QUALITY,
          print_background: true,
        ).to_jpeg
      end
    end
  end
end
