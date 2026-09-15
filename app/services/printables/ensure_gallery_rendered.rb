# frozen_string_literal: true

# Renders whatever a listing's CURATED gallery is missing or has stale, and
# nothing else:
#
#   styled refs — Boards::Printables::RenderStyledSlides with only the variants
#                 needed. Styled slides are shared across listings.
#   legacy refs — the existing Boards::Printables::RenderListingImages path,
#                 which renders the whole legacy set (per listing when the
#                 listing carries a topic override, exactly as publishing an
#                 uncurated listing does).
#
# Grover work: call it from Sidekiq (the publish job), never a request thread.
# A no-op for a listing that was never curated — that listing keeps the legacy
# publish path untouched.
module Printables
  class EnsureGalleryRendered
    Result = Struct.new(:styled_variants, :legacy_rendered, keyword_init: true)

    def initialize(listing)
      @listing = listing
      @printable = listing.board_printable
    end

    def call
      return Result.new(styled_variants: [], legacy_rendered: false) unless listing.curated_gallery?

      stale = listing.stale_gallery_refs
      styled = stale.select(&:styled?).map(&:variant).uniq
      legacy = stale.any?(&:legacy?)

      Boards::Printables::RenderStyledSlides.new(printable: printable, variants: styled).call if styled.any?

      if legacy
        Boards::Printables::RenderListingImages.new(
          printable: printable, listing: listing.topic_override.presence && listing,
        ).call
      end

      if styled.any? || legacy
        printable.reload
        listing.reload
      end

      Result.new(styled_variants: styled, legacy_rendered: legacy)
    end

    private

    attr_reader :listing, :printable
  end
end
