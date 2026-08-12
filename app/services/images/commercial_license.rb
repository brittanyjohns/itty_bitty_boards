# app/services/images/commercial_license.rb
#
# Decides whether an image may appear in a product we SELL, and what
# obligations come with it.
#
# Grounded in the actual library (measured 2026-07-22, 10,101 docs) — see
# docs/superpowers/specs/2026-07-22-internal-api-search-endpoints-design.md
# for the full breakdown. Two facts drive the shape of this code:
#
#   * Doc#license is the ONLY populated license field (Image#license has zero
#     rows) and its jsonb key is "type", not "license".
#   * Doc#license is populated only on ObfImport docs. OpenSymbol-sourced docs
#     carry their license on the OpenSymbol row instead.
#
# The predicate FAILS CLOSED: anything unrecognized is unsafe. A false negative
# costs one missing picture; a false positive costs a license violation.
module Images
  module CommercialLicense
    # License types usable in a product we sell, with no share-alike burden.
    # Matched case-insensitively after normalization, so "CC By 3.0" and
    # "CC BY" both land on "cc by".
    COMMERCIAL_TYPES = [
      "public domain",
      "cc0",
      "cc by",
    ].freeze

    # source_types whose provenance we cannot vouch for. Scraped or unknown.
    UNTRUSTED_SOURCE_TYPES = ["GoogleSearch", nil, ""].freeze

    # We generated it; it's ours. Text tiles are rendered in-house in an OFL
    # font, whose license covers the font software and not the rendered pixels,
    # so a printable containing one is sellable.
    OWNED_SOURCE_TYPES = ["OpenAI", Doc::SOURCE_TYPE_TEXT_TILE].freeze

    Result = Struct.new(:license, :type, :commercial_safe, :attribution_required, :share_alike) do
      def commercial_safe? = !!commercial_safe

      def attribution_required? = !!attribution_required

      def share_alike? = !!share_alike
    end

    class << self
      def for(doc, include_share_alike: false)
        # Resolved once — for OpenSymbol docs this hits the DB.
        license = LicenseResolution.resolve(doc)
        protected_symbol = license == :protected
        license = nil if protected_symbol

        type = LicenseResolution.normalize_type(license.is_a?(Hash) ? license["type"] : license)

        share_alike    = type.present? && type.include?("sa")
        non_commercial = type.present? && type.include?("nc")
        no_derivatives = type.present? && type.include?("nd")
        attribution    = type.present? && type.start_with?("cc by")

        safe = safe?(
          doc: doc,
          type: type,
          protected_symbol: protected_symbol,
          share_alike: share_alike,
          non_commercial: non_commercial,
          no_derivatives: no_derivatives,
          include_share_alike: include_share_alike,
        )

        Result.new(license.is_a?(Hash) ? license : nil, type.presence, safe, attribution, share_alike)
      end

      private

      def safe?(doc:, type:, protected_symbol:, share_alike:, non_commercial:, no_derivatives:, include_share_alike:)
        return false if protected_symbol
        return true  if OWNED_SOURCE_TYPES.include?(doc.source_type)
        return false if UNTRUSTED_SOURCE_TYPES.include?(doc.source_type)
        return false if type.blank?
        return false if non_commercial || no_derivatives
        return false if share_alike && !include_share_alike

        # Strip the SA suffix before matching so "cc by-sa" can match "cc by"
        # once the caller has opted into share-alike.
        base = type.sub(/-sa\b/, "").strip
        COMMERCIAL_TYPES.any? { |allowed| base == allowed || base.start_with?("#{allowed} ") }
      end
    end
  end
end
