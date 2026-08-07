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
        pdf << CombinePDF.parse(wrapper_for(:cover, variant))
        pdf << CombinePDF.parse(wrapper_for(:how_to_use, variant))
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

      # The cover and the how-to-use page both make claims about the file they
      # sit in, so the low-ink FILE gets its own render of each: an ink-light
      # cover, and instructions that describe a low-ink print rather than the
      # colour one it doesn't contain.
      #
      # RenderWrappers only produces those for a set, so fall back rather than
      # assuming the key is there — the single-board file is one document
      # holding both halves and has no low-ink identity to honour.
      def wrapper_for(key, variant)
        return wrappers[key] unless variant == BoardPrintable::VARIANT_LOW_INK

        wrappers[:"#{key}_low_ink"] || wrappers[key]
      end
    end
  end
end
