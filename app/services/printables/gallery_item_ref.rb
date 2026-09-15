# frozen_string_literal: true

# One entry in a listing's curated Etsy gallery
# (`board_printable_listings.gallery_items`), e.g. "styled:styled_hero".
#
# A ref is `<prefix>:<value>`, and both halves are checked against an
# ALLOWLIST — never "anything that isn't obviously wrong". Same rule as
# `BoardPrintable::KIND_DOWNLOADABLE` and every per-listing asset partition: a
# selection made by exclusion stays correct only until the next kind of blob
# exists, and here the next kind (scene compositions) is already planned.
#
# Resolving a ref to a blob prefers the LISTING's own render (blob metadata
# `listing_id`) over the shared one, which is what lets a listing carrying a
# topic override show its own slides in a gallery that otherwise inherits.
module Printables
  class GalleryItemRef
    # Etsy's photo cap. The listing video is a separate slot.
    MAX_ITEMS = 10

    SEPARATOR = ":"

    # prefix => the values it may name. Lambdas so the constants resolve at call
    # time rather than at load order.
    PREFIXES = {
      "legacy" => -> { BoardPrintable::LISTING_IMAGE_ORDER },
      "styled" => -> { BoardPrintable::STYLED_IMAGE_VARIANTS },
      # EXTENSION POINT: "composition" => -> { <composition ids> } lands with the scene engine.
    }.freeze

    # Named so a ref using one gets a message saying "not yet", rather than
    # reading as a typo.
    RESERVED_PREFIXES = %w[composition].freeze

    # What "Use suggested order" writes. Rank 1 is Etsy's search thumbnail and
    # belongs to a photograph of the product in a real room (the shop audit
    # rated those "Strong"; flat art "OK/Weak"). The styled hero and
    # what's-included REPLACE their legacy twins rather than sitting beside
    # them — the gallery was pruned twice already for showing a buyer the same
    # slide twice. Mockups and content slides alternate, as in
    # LISTING_IMAGE_ORDER.
    SUGGESTED = %w[
      legacy:on_paper
      styled:styled_hero
      legacy:on_a_device
      legacy:flip_book
      styled:styled_whats_included
      legacy:on_paper_alt
      legacy:assemble
      legacy:on_a_device_alt
      legacy:page_index
      legacy:about
    ].freeze

    attr_reader :prefix, :value

    # => a GalleryItemRef, or nil for anything outside the allowlist.
    def self.parse(raw)
      error_for(raw) ? nil : new(*raw.split(SEPARATOR, 2))
    end

    # => nil when the ref is valid, else a short reason naming it.
    def self.error_for(raw)
      return "#{raw.inspect} is not a gallery item" unless raw.is_a?(String)

      prefix, value = raw.split(SEPARATOR, 2)
      return "#{raw} can't be used yet — #{prefix} images aren't supported" if RESERVED_PREFIXES.include?(prefix)
      return "#{raw} has an unknown kind" unless PREFIXES.key?(prefix)
      return "#{raw} names an image that doesn't exist" unless PREFIXES.fetch(prefix).call.include?(value)

      nil
    end

    def self.valid?(raw) = error_for(raw).nil?

    def self.build(prefix, value) = parse("#{prefix}#{SEPARATOR}#{value}")

    # Every ref an admin may pick today, legacy slides in rank order first.
    def self.catalogue
      PREFIXES.flat_map { |prefix, values| values.call.map { |value| build(prefix, value) } }
    end

    def initialize(prefix, value)
      @prefix = prefix
      @value = value
      freeze
    end

    def legacy? = prefix == "legacy"

    def styled? = prefix == "styled"

    # Both current prefixes name a blob `variant`.
    def variant = value

    def to_s = "#{prefix}#{SEPARATOR}#{value}"

    def ==(other) = other.is_a?(self.class) && other.to_s == to_s
    alias eql? ==

    def hash = to_s.hash

    def label
      name = styled? ? value.delete_prefix("styled_") : value
      "#{name.humanize} (#{prefix})"
    end

    # The blob this ref shows on `listing`: the listing's own render first, then
    # the shared one. nil when neither has been rendered.
    def resolve(listing)
      candidates = listing.board_printable.all_image_files.select { |f| f.metadata["variant"] == variant }
      candidates.find { |f| f.metadata["listing_id"] == listing.id } ||
        candidates.find { |f| f.metadata["listing_id"].nil? }
    end

    # Resolves to a blob rendered for THIS listing, not the shared one.
    def resolves_to_own?(listing)
      resolve(listing)&.metadata&.dig("listing_id") == listing.id
    end
  end
end
