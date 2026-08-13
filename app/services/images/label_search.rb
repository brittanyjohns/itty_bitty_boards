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

    attr_reader :match, :limit, :commercial_safe, :include_share_alike, :resolve

    def initialize(match: "exact", limit: DEFAULT_LIMIT, commercial_safe: false, include_share_alike: false, resolve: false)
      @match = match.to_s == "prefix" ? "prefix" : "exact"
      @limit = clamp(limit)
      @commercial_safe = commercial_safe
      @include_share_alike = include_share_alike
      @resolve = resolve
    end

    def call(label)
      label = label.to_s.strip
      return [] if label.blank?

      results = []
      seen = Set.new

      # Tiers are lazy: a tier is only queried when the one above it failed to
      # fill `limit`, so an exact hit costs one lookup, not four.
      tiers(label).each do |candidates, kind|
        candidates.call.each do |image|
          next unless seen.add?(image.id)

          row = serialize(image, kind)
          results << row if row
          break if results.size >= limit
        end
        break if results.size >= limit
      end

      results
    end

    private

    def base_scope
      Image.default_public.searchable.with_artifacts
    end

    # Ranked tiers, best first. Everything below the first tier existed before;
    # the two additions are the `resolve` tier and the literal-equality tier.
    #
    # `search_by_exact_label` is NOT an equality match — it is a pg_search
    # tsearch scope with `prefix: false`, so it matches the *word* "want"
    # anywhere in a label ("i want pasta", "want slide") and orders by ts_rank
    # with no tiebreak. The genuinely exact row could therefore be outranked by
    # phrase matches and truncated away at `limit`, which is how a pre-flight
    # check reported core vocabulary as having no art while `bulk` was happily
    # attaching an exact-label image for the same word (#575). The literal tier
    # runs first and orders exactly the way Boards::ImageResolver does, so the
    # two endpoints agree on which Image wins a label.
    def tiers(label)
      list = []
      list << [-> { resolved_candidates(label) }, "resolve"] if resolve
      list << [-> { literal_matches(label) }, "exact"]
      list << [-> { base_scope.search_by_exact_label(label).limit(fetch_limit) }, "exact"] if match != "prefix"
      list << [-> { base_scope.search_by_label(label).limit(fetch_limit) }, "prefix"]
      list
    end

    # Exactly what `POST /api/internal/boards/:id/board_images/bulk` would
    # attach for this label. The resolver reads a DIFFERENT slice of the library
    # than search does — `owner.images` (the default admin's, private ones
    # included) before the public scope — so a label can resolve to an image
    # ordinary search can never return. This tier is the caller's only way to
    # see that ahead of the write.
    #
    # Returns nothing when no art exists for the label: the resolver would then
    # attach a blank image and queue AI generation, and search must not
    # pre-create that Image as a side effect of a read.
    def resolved_candidates(label)
      owner = User.find_by(id: User::DEFAULT_ADMIN_ID)
      return [] if owner.nil?

      Array(Boards::ImageResolver.best_arted_for(label, owner))
    end

    # Literal, case-insensitive label equality, ordered the way
    # Boards::ImageResolver orders: most artwork first, lowest id to break ties.
    #
    # Two queries on purpose. `with_artifacts` is an `includes`, and mixing it
    # with the `left_joins(:docs) + GROUP BY` needed for the doc-count ordering
    # makes Rails eager_load into the grouped query. Rank ids first, then load
    # the page with its preloads intact.
    def literal_matches(label)
      ids = Image.default_public.searchable
                 .where("LOWER(images.label) = LOWER(?)", label)
                 .left_joins(:docs)
                 .group("images.id")
                 .having("COUNT(docs.id) > 0")
                 .order(Arel.sql("COUNT(docs.id) DESC, images.id ASC"))
                 .limit(fetch_limit)
                 .pluck(:id)
      return [] if ids.empty?

      by_id = Image.where(id: ids).with_artifacts.index_by(&:id)
      ids.filter_map { |id| by_id[id] }
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
      # A resolve row is never filtered out: the point of the tier is "here is
      # what bulk will attach", and hiding an unsafe pick behind the
      # commercial_safe filter reports "no art" for a label that will in fact
      # get art. The flags below let the caller judge it.
      return nil if commercial_safe && kind != "resolve" && !license.commercial_safe?

      blob = doc.image.blob

      {
        id: image.id,
        label: image.label,
        match: kind,
        # The Doc the URLs below describe. Callers that let a human PICK one of
        # several results (the board builder's review screen) need to name the
        # exact picture afterwards, and an image id can't do that — which doc
        # an image resolves to changes as art is added.
        doc_id: doc.id,
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

    def library_doc(image)
      self.class.library_doc(image)
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
    #
    # Deliberately filters the already-loaded `docs` association in Ruby
    # instead of `image.docs.where(...)`. base_scope preloads docs (and their
    # attachments/blobs) via `with_artifacts`; a `.where` here would issue a
    # fresh query per image, defeating that preload and reintroducing an N+1.
    # `docs` carries no default ordering scope, so `max_by(&:id)` is
    # equivalent to the previous `.order(:id).last` ("most recent" wins).
    # Do not "optimize" this back into a `.where`.
    #
    # Exposed as a class method as well so the internal images#show endpoint
    # reports licensing for the same Doc a search result would describe.
    def self.library_doc(image)
      image.docs.select { |doc| [nil, User::DEFAULT_ADMIN_ID].include?(doc.user_id) }.max_by(&:id)
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
