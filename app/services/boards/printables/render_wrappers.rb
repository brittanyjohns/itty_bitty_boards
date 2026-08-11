# The Letter portrait pages that bookend the board pages: cover, how-to-use,
# license, about (credits) — plus a second, ink-light cover for a set.
#
# Started as a port of the printables pipeline's step 08 and has since diverged;
# the design now lives here and the pipeline is the side that needs to catch up.
# See layouts/pdf_printable.html.erb for the rules that hold across the pages.
#
# Each is its own Grover render so the merge can order them freely and so a
# wrapper's portrait orientation survives next to landscape board pages.
module Boards
  module Printables
    class RenderWrappers
      # Navy at 400px, on WHITE — the pipeline fills its QR with cream to melt
      # into a cream page, but ours sits inside a white card in both the colour
      # and ink-light variants, where a cream fill prints as a visible square
      # inside the card. White also maximises scan contrast, which is the whole
      # job of this image.
      QR_DARK = "#13496f".freeze
      QR_LIGHT = "#FFFFFF".freeze
      QR_SIZE = 400

      def initialize(board:, board_count:, topic: nil)
        @board = board
        @board_count = board_count
        @topic = topic.presence
      end

      # => { cover:, how_to_use:, license:, credits: } of PDF bytes, plus
      #    cover_low_ink: and how_to_use_low_ink: for a set.
      #
      # A set is emitted as two separate FILES (MergePdf), so the two pages that
      # make claims about the document they sit in get rendered twice — once per
      # variant — and MergePdf binds the matching one into each file. Without
      # that, the low-ink file opens on a full-bleed gradient cover and then
      # explains a colour print it doesn't contain.
      #
      # A single board is ONE file holding both a colour and a low-ink half, so
      # it has no per-variant identity: one cover, one how-to-use, and the copy
      # describes the pair of halves.
      def call
        wrappers = {
          cover: render("cover", assigns: cover_assigns),
          how_to_use: render("how_to_use", assigns: how_to_use_assigns),
          license: render("license", assigns: {}),
          credits: render("credits", assigns: credits_assigns),
        }

        return wrappers unless set?

        wrappers.merge(
          cover_low_ink: render("cover", assigns: cover_assigns.merge(ink_light: true)),
          how_to_use_low_ink: render("how_to_use", assigns: how_to_use_assigns(low_ink: true)),
        )
      end

      # Public because RenderListingImages renders the SAME cover as a PNG for
      # the marketplace gallery. Sharing the assigns rather than rebuilding them
      # is what keeps the listing's first image identical to the product's first
      # page — including the QR target, which is easy to get subtly wrong.
      def cover_assigns
        {
          title: Boards::AssetRendering.board_title_for(board),
          subtitle: subtitle,
          logo: Boards::AssetRendering.logo_base64,
          qr_data_url: qr_data_url,
          public_url: public_url,
        }
      end

      private

      attr_reader :board, :board_count, :topic

      def set? = board_count > 1

      # `low_ink` is only ever true for a set, where this page is bound into the
      # low-ink file alone and must describe that file rather than the pair.
      def how_to_use_assigns(low_ink: false)
        {
          is_set: set?,
          low_ink: low_ink,
          topic: topic,
          noun: set? ? "set of #{board_count} communication boards" : "communication board",
        }
      end

      def credits_assigns
        {
          logo: Boards::AssetRendering.logo_base64,
          qr_data_url: qr_data_url,
          public_url: public_url,
        }
      end

      # Printed as text beside the QR on the cover and the About page. A
      # laminated or photocopied sheet whose QR has degraded — or a reader with
      # no camera — still needs a way back to the board.
      def public_url
        @public_url ||= board_url.delete_prefix("https://")
      end

      def board_url
        @board_url ||= "#{CollectPages::QR_BASE_URL}/#{CollectPages.qr_key_for(board)}"
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
          png = RQRCode::QRCode.new(board_url).as_png(
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
