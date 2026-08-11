# frozen_string_literal: true

# The "what's included" bullet list, in one place.
#
# It is rendered twice — once as text in the listing description
# (Etsy::ListingCopy) and once as the what's-included gallery image
# (Boards::Printables::RenderListingImages) — and a buyer flipping between the
# two should see one voice, not two. Duplicating the list is how they drift.
module Printables
  module IncludedItems
    module_function

    # The one line that describes the actual document, and the only line that
    # changes with the printable. A multi-board bundle ships every board twice
    # (color + low-ink) and arrives as TWO files, so quoting a single page count
    # badly understates it.
    def headline(board_count:, page_count:)
      pages = page_count.to_i

      if board_count > 1
        return "#{board_count} boards — 2 PDFs (full color + low-ink)" unless pages.positive?

        "#{board_count} boards, #{pages} pages — 2 PDFs (full color + low-ink)"
      else
        pages.positive? ? "#{pages}-page board PDF — color + low-ink" : "Board PDF — color + low-ink"
      end
    end

    # The audio companion leads because it is the single biggest differentiator
    # against every other AAC printable on the marketplace, and the phrase has to
    # name the SPEAKING — "free online version" reads as a PDF viewer, and "voice
    # output" is jargon a parent shopping for their kid doesn't parse.
    def all(board_count:, page_count:)
      [
        headline(board_count: board_count, page_count: page_count),
        'Print-ready Letter (8.5" x 11")',
        "Free audio companion — tap any word and it talks",
        "Curated AAC-aligned vocabulary",
        "Personal & classroom license",
      ]
    end
  end
end
