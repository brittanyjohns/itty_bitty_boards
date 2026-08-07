# Port of the printables pipeline's step 09 (merge-final-pdf), using
# combine_pdf where the pipeline uses pdf-lib.
#
# Merging per-page renders rather than printing one long HTML document is what
# lets portrait wrappers sit next to landscape board pages: a merge preserves
# each page's own size, while a single Chrome print would have to force one
# @page orientation on everything.
module Boards
  module Printables
    class MergePdf
      MergedFile = Struct.new(:variant, :filename, :bytes, :page_count, keyword_init: true)

      def initialize(wrappers:, pages:, boards:, slug:)
        @wrappers = wrappers
        @pages = pages
        @boards = boards
        @slug = slug.presence || "board"
      end

      # Single board  => one file:  cover, how-to-use, colour, low-ink, license, credits
      # Subboard tree => two files: each is cover, how-to-use, that variant's N
      #                  board pages, license, credits. No combined master —
      #                  the cover and its root QR are duplicated into both, by
      #                  design, so either file stands alone.
      def call
        return [single_file] if boards.length <= 1

        [
          bundle_file(BoardPrintable::VARIANT_COLOR, "#{slug}.color.pdf"),
          bundle_file(BoardPrintable::VARIANT_LOW_INK, "#{slug}.low-ink.pdf"),
        ]
      end

      private

      attr_reader :wrappers, :pages, :boards, :slug

      def single_file
        build(
          variant: BoardPrintable::VARIANT_FULL,
          filename: "#{slug}.pdf",
          board_pages: pages,
        )
      end

      def bundle_file(variant, filename)
        build(
          variant: variant,
          filename: filename,
          board_pages: pages.select { |page| page.variant == variant },
        )
      end

      def build(variant:, filename:, board_pages:)
        pdf = CombinePDF.new
        pdf << CombinePDF.parse(cover_for(variant))
        pdf << CombinePDF.parse(wrappers[:how_to_use])
        board_pages.each { |page| pdf << CombinePDF.parse(page.pdf_bytes) }
        pdf << CombinePDF.parse(wrappers[:license])
        pdf << CombinePDF.parse(wrappers[:credits])

        MergedFile.new(
          variant: variant,
          filename: filename,
          bytes: pdf.to_pdf,
          page_count: pdf.pages.length,
        )
      end

      # The low-ink FILE opens on an ink-light cover so its first page doesn't
      # contradict its filename. RenderWrappers only produces one for a set, so
      # fall back to the colour cover rather than assuming the key is there —
      # the single-board file is one document holding both halves and has no
      # low-ink identity to honour.
      def cover_for(variant)
        return wrappers[:cover] unless variant == BoardPrintable::VARIANT_LOW_INK

        wrappers[:cover_low_ink] || wrappers[:cover]
      end
    end
  end
end
