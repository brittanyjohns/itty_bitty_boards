# frozen_string_literal: true

# Whether a printable's title shares Etsy's shop-grid truncation window with
# another printable's — the check that would have caught every non-core
# listing opening on the same fixed head term with nothing distinguishing
# them before the cut.
#
# Etsy truncates a listing's title to roughly PREFIX_LENGTH characters in the
# shop grid, so two titles identical up to that point are indistinguishable
# while browsing and compete with each other instead of reaching a buyer
# looking for either one specifically.
#
# WARNS, never blocks — same contract as Etsy::TagOverlap. A shared head term
# is often correct (every listing should open "AAC …"); only an identical
# PREFIX is a problem, and only a human can tell a coincidence from a listing
# that forgot to say what it is.
#
# Read-only and side-effect free — safe to call from a view.
module Etsy
  class TitlePrefixOverlap
    # Roughly where Etsy's shop grid stops showing a title.
    PREFIX_LENGTH = 34

    # Only printables that already have saved listing copy are compared, and
    # only the most recent slice of them — see Etsy::TagOverlap::SCAN_LIMIT.
    SCAN_LIMIT = 200

    MAX_MATCHES = 3

    Match = Struct.new(:printable, :listing, :prefix, keyword_init: true) do
      # A sibling listing on the SAME printable has the same board name, so it
      # has to say which listing it is or the warning reads as a bug.
      def label
        base = printable.board&.name || "Board ##{printable.board_id}"
        return base if listing.nil?

        "#{base} — #{listing.label.presence || listing.purpose} listing"
      end
    end

    # Takes a printable (the base copy) or a single BoardPrintableListing.
    def initialize(subject, title: nil)
      @listing = subject if subject.is_a?(BoardPrintableListing)
      @printable = @listing&.board_printable || subject
      @prefix = normalize(title || default_title)
    end

    def any? = matches.any?

    def matches
      @matches ||= begin
        if @prefix.blank?
          []
        else
          candidates.select { |candidate| candidate[:prefix] == @prefix }
                    .first(MAX_MATCHES)
                    .map { |candidate| Match.new(printable: candidate[:printable], listing: candidate[:listing], prefix: @prefix) }
        end
      end
    end

    private

    def default_title
      (@listing&.resolved_copy || @printable.listing_copy_or_default)["title"]
    end

    def candidates = sibling_candidates + printable_candidates

    # Other listings on this same printable. Their RESOLVED copy, since a
    # listing that overrides nothing still ships the printable's title.
    #
    # When the subject is the printable itself (no @listing), a listing with
    # no title override of its own isn't a sibling to compare against: it
    # ships the exact title being compared, so it would always "match" itself.
    def sibling_candidates
      return [] if @printable.id.nil?

      @printable.etsy_listings.reject { |other| other.id == @listing&.id }
                .reject { |other| @listing.nil? && other.listing_copy.to_h["title"].blank? }
                .filter_map do |other|
        prefix = normalize(other.resolved_copy["title"])
        { printable: @printable, listing: other, prefix: prefix } if prefix.present?
      end
    end

    def printable_candidates
      scope = BoardPrintable.includes(:board).order(created_at: :desc)
      scope = scope.where.not(id: @printable.id) if @printable.id
      scope.limit(SCAN_LIMIT).filter_map do |other|
        prefix = normalize(other.listing_copy.to_h["title"])
        { printable: other, listing: nil, prefix: prefix } if prefix.present?
      end
    end

    def normalize(title) = title.to_s.strip.downcase[0, PREFIX_LENGTH]
  end
end
