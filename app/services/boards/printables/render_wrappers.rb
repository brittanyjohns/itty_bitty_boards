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
      #    cover_low_ink: for a set.
      #
      # The low-ink cover is a second render of the same template with
      # `ink_light` set, which the layout turns into fills-become-outlines. It
      # exists only for a set, where MergePdf emits a separate low-ink FILE that
      # would otherwise open on a full-bleed gradient — a cover that contradicts
      # the promise its filename makes. A single board is one file containing
      # both halves, so it keeps the one colour cover.
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
        )
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
          public_url: public_url,
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
