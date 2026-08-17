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
      def initialize(board:, board_count:, topic: nil)
        @board = board
        @board_count = board_count
        @topic = topic.presence
      end

      # => { cover:, how_to_use:, license:, credits: } of PDF bytes, plus
      #    cover_low_ink:, how_to_use_low_ink: and how_to_use_trim_ready: for
      #    a set. The keys are `<page>_<variant>` because that is how MergePdf
      #    looks them up.
      #
      # A set is emitted as three separate FILES (MergePdf), so the two pages
      # that make claims about the document they sit in get rendered per variant
      # and MergePdf binds the matching one into each file. Without that, the
      # low-ink file opens on a full-bleed gradient cover and then explains a
      # colour print it doesn't contain.
      #
      # No cover_trim_ready: that file is full colour, so the colour cover is
      # already the right one — only its board pages differ. MergePdf falls back
      # to the unsuffixed key rather than needing one rendered.
      #
      # A single board is ONE file holding every variant of the page, so it has
      # no per-variant identity: one cover, one how-to-use, and the copy
      # describes the set of halves.
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
          how_to_use_low_ink: render("how_to_use", assigns: how_to_use_assigns(variant: BoardPrintable::VARIANT_LOW_INK)),
          how_to_use_trim_ready: render("how_to_use", assigns: how_to_use_assigns(variant: BoardPrintable::VARIANT_TRIM_READY)),
        )
      end

      # Public for historical reasons: RenderListingImages used to render this
      # same cover as the gallery's first image, and shared the assigns so the
      # two could not drift. That slide was retired when the gallery became
      # purpose-built marketing art, so this now has one caller — the PDF.
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

      # `variant` is only ever set for a board SET, where this page is bound
      # into one variant's file alone and must describe that file rather than
      # the collection of halves a single-board document holds.
      def how_to_use_assigns(variant: nil)
        {
          is_set: set?,
          variant: variant,
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
        @board_url ||= Qr.target_url_for(board)
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
        @qr_data_url ||= Qr.data_url_for(board_url)
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
