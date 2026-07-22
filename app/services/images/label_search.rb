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

    # Only ~36% of the library is commercial-safe. `.limit(limit)` in SQL
    # followed by Ruby-side commercial_safe filtering can drop rows that
    # would have passed if we'd fetched further down the ranking — a real
    # gap gets misreported as "no safe image for this label". When
    # commercial_safe filtering is active, over-fetch before filtering, then
    # truncate to `limit` after. Capped so a MAX_LIMIT request can't balloon
    # into an unbounded scan.
    COMMERCIAL_SAFE_OVERFETCH_MULTIPLIER = 4
    COMMERCIAL_SAFE_FETCH_CEILING = 200

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
        [base_scope.search_by_label(label).limit(fetch_limit), "prefix"]
      else
        exact = base_scope.search_by_exact_label(label).limit(fetch_limit).to_a
        return [exact, "exact"] if exact.any?

        [base_scope.search_by_label(label).limit(fetch_limit), "prefix"]
      end
    end

    # Behaviour is unchanged when commercial_safe filtering is off.
    def fetch_limit
      return limit unless commercial_safe

      (limit * COMMERCIAL_SAFE_OVERFETCH_MULTIPLIER).clamp(limit, COMMERCIAL_SAFE_FETCH_CEILING)
    end

    def serialize(image, kind)
      doc = library_doc(image)
      return nil unless doc&.image&.attached?

      license = Images::CommercialLicense.for(doc, include_share_alike: include_share_alike)
      return nil if commercial_safe && !license.commercial_safe?

      blob = doc.image.blob

      {
        id: image.id,
        label: image.label,
        match: kind,
        # doc.tile_url materializes the ActiveStorage variant synchronously
        # (download original + libvips transform + upload) on first access.
        # This endpoint can return up to MAX_LIMIT results in one response,
        # so calling it unconditionally risks up to MAX_LIMIT inline
        # transcodes in a single request — a timeout risk. Only surface a
        # tile URL when the variant is already processed (cheap check, no
        # transcode); otherwise src is nil so callers can tell "no thumbnail
        # yet" apart from a real one. Do not fall back to the original here.
        src: doc.tile_variant_processed? ? doc.tile_url : nil,
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

    # image.display_doc(nil) is NOT safe here: for an admin-owned image it
    # resolves to `docs.last` with no filter on doc.user_id at all. Non-admin
    # users can attach their own Docs to shared public admin-owned Images
    # (via API::ImagesController#crop / attach_doc_to_image, which permits
    # any image where is_private IS NOT TRUE), so display_doc(nil) can return
    # a real user's private upload here — served on an unsigned, permanent
    # CloudFront URL to an internal pipeline that prints it into a product.
    # Restrict to library-owned docs (nil or the default admin) instead, and
    # keep the same "most recent" preference display_doc uses. Do not change
    # Image#display_doc itself — it drives legitimate per-user doc resolution
    # everywhere else in the app.
    def library_doc(image)
      image.docs.where(user_id: [nil, User::DEFAULT_ADMIN_ID]).order(:id).last
    end

    # A blank value (omitted keyword arg, nil, or an empty string — the
    # shape `params[:limit]` takes for a present-but-empty `?limit=`, which
    # is truthy in Ruby) means "use the default". An explicit out-of-range
    # number (0, negative, or above MAX_LIMIT) is a caller error and gets
    # clamped into range instead of silently replaced with the default.
    def clamp(value)
      return DEFAULT_LIMIT if value.blank?

      value.to_i.clamp(1, MAX_LIMIT)
    end
  end
end
