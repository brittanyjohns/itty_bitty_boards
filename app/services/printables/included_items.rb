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
    # changes with the printable. A multi-board bundle ships every board three
    # times (color, low-ink, trim-ready) and arrives as THREE files, so quoting
    # a single page count badly understates it.
    #
    # "Trim-ready" rather than "header-less": the buyer-facing name has to say
    # what it's FOR. The band is what gets cut off before laminating, and this
    # is the copy that survives the cut.
    def headline(board_count:, page_count:)
      pages = page_count.to_i

      if board_count > 1
        return "#{board_count} boards — 3 PDFs (full color + low-ink + trim-ready)" unless pages.positive?

        "#{board_count} boards, #{pages} pages — 3 PDFs (full color + low-ink + trim-ready)"
      else
        pages.positive? ? "#{pages}-page board PDF — color, low-ink + trim-ready" : "Board PDF — color, low-ink + trim-ready"
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
