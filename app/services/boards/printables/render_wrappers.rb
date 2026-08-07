# Port of the printables pipeline's step 08 (render-wrappers). Four Letter
# portrait pages that bookend the board pages: cover, how-to-use, license,
# credits.
#
# Each is its own Grover render so the merge can order them freely and so a
# wrapper's portrait orientation survives next to landscape board pages.
module Boards
  module Printables
    class RenderWrappers
      # Matches the pipeline's cover/credits QR exactly: navy on cream at
      # 400px, so an in-app printable and a pipeline printable are
      # indistinguishable.
      QR_DARK = "#13496f".freeze
      QR_LIGHT = "#FBF7F1".freeze
      QR_SIZE = 400

      def initialize(board:, board_count:, topic: nil)
        @board = board
        @board_count = board_count
        @topic = topic.presence
      end

      # => { cover: bytes, how_to_use: bytes, license: bytes, credits: bytes }
      def call
        {
          cover: render("cover", assigns: cover_assigns),
          how_to_use: render("how_to_use", assigns: how_to_use_assigns),
          license: render("license", assigns: {}),
          credits: render("credits", assigns: credits_assigns),
        }
      end

      private

      attr_reader :board, :board_count, :topic

      def set? = board_count > 1

      def cover_assigns
        {
          title: Boards::AssetRendering.board_title_for(board),
          subtitle: subtitle,
          logo: Boards::AssetRendering.logo_base64,
          qr_data_url: qr_data_url,
        }
      end

      def how_to_use_assigns
        {
          is_set: set?,
          topic: topic,
          noun: set? ? "set of #{board_count} communication boards" : "communication board",
        }
      end

      def credits_assigns
        { logo: Boards::AssetRendering.logo_base64, qr_data_url: qr_data_url }
      end

      def subtitle
        return "Words for #{topic}" if topic
        return "A set of #{board_count} communication boards" if set?

        "A printable communication board"
      end

      # The cover's QR is the one page whose QR targets the ROOT board — it
      # represents the whole bundle. Every interior board page targets its own
      # board (see CollectPages).
      def qr_data_url
        @qr_data_url ||= begin
          key = CollectPages.qr_key_for(board)
          png = RQRCode::QRCode.new("#{CollectPages::QR_BASE_URL}/#{key}").as_png(
            bit_depth: 8,
            border_modules: 0,
            color_mode: ChunkyPNG::COLOR_TRUECOLOR,
            color: QR_DARK,
            fill: QR_LIGHT,
            size: QR_SIZE,
          )
          "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
        end
      end

      def render(template, assigns:)
        html = ApplicationController.render(
          template: "api/board_printables/#{template}",
          layout: "pdf_printable",
          assigns: assigns,
          formats: [:html],
        )

        Grover.new(
          html,
          format: "Letter",
          landscape: false,
          viewport: { width: 612, height: 792 },
          full_page: false,
          prefer_css_page_size: true,
          print_background: true,
        ).to_pdf
      end
    end
  end
end
