# app/services/images/label_search.rb
#
# Label search over the public image library for the internal API.
#
# Two things callers get wrong, so they are explicit in the payload:
#
#   * `src` is the 288px WebP tile (previews). `original_url` is the untouched
#     full-resolution upload — that is what a printable must download.
#   * licensing flags come from Images::CommercialLicense and are ALWAYS
#     present, whether or not the request filtered on them.
module Images
  class LabelSearch
    MAX_LIMIT = 50
    DEFAULT_LIMIT = 10

    attr_reader :match, :limit, :commercial_safe, :include_share_alike

    def initialize(match: "exact", limit: DEFAULT_LIMIT, commercial_safe: false, include_share_alike: false)
      @match = match.to_s == "prefix" ? "prefix" : "exact"
      @limit = clamp(limit)
      @commercial_safe = commercial_safe
      @include_share_alike = include_share_alike
    end

    def call(label)
      label = label.to_s.strip
      return [] if label.blank?

      matched, kind = fetch(label)
      matched.filter_map { |image| serialize(image, kind) }.first(limit)
    end

    private

    def base_scope
      Image.default_public.searchable.with_artifacts
    end

    # Exact first, prefix as a fallback — labels are stored inconsistently
    # enough that exact-only would produce spurious empty results.
    def fetch(label)
      if match == "prefix"
        [base_scope.search_by_label(label).limit(limit), "prefix"]
      else
        exact = base_scope.search_by_exact_label(label).limit(limit).to_a
        return [exact, "exact"] if exact.any?

        [base_scope.search_by_label(label).limit(limit), "prefix"]
      end
    end

    def serialize(image, kind)
      doc = image.display_doc(nil)
      return nil unless doc&.image&.attached?

      license = Images::CommercialLicense.for(doc, include_share_alike: include_share_alike)
      return nil if commercial_safe && !license.commercial_safe?

      blob = doc.image.blob

      {
        id: image.id,
        label: image.label,
        match: kind,
        src: doc.tile_url,
        original_url: doc.display_url,
        content_type: blob&.content_type,
        width: blob&.metadata&.dig("width"),
        height: blob&.metadata&.dig("height"),
        source_type: doc.source_type,
        license: license.license,
        commercial_safe: license.commercial_safe?,
        attribution_required: license.attribution_required?,
        share_alike: license.share_alike?,
      }
    end

    # Only DEFAULT_LIMIT's absence (an omitted keyword arg) should fall back
    # to the default; an explicit 0 or negative limit is a caller error and
    # gets clamped up to 1, not silently replaced with the default.
    def clamp(value)
      value.to_i.clamp(1, MAX_LIMIT)
    end
  end
end
