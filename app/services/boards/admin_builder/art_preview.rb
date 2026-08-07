module Boards
  module AdminBuilder
    # What the library would put on each tile, resolved WITHOUT WRITING ANYTHING.
    #
    # 🚨 This is the reason the builder is two steps, and the one rule that must
    # not be relaxed: `Boards::ImageResolver.resolve` / `.resolve_all` CREATE a
    # blank Image row for any label with no match. Calling either from here
    # would litter the library with blanks every time an admin pressed Preview
    # — and would report "art exists" for a row it had just invented. Resolution
    # here goes through Images::LabelSearch, whose `resolve` tier calls the
    # read-only `best_arted_for`. `resolve_all` belongs in Build, inside the
    # transaction, where creating blanks is the intended outcome.
    #
    # Exact vs. fuzzy is the point of the review screen. A hit whose own label
    # differs from the requested word is a judgment call, not a match: "my" has
    # resolved to art labelled "too tired to speak as it uses a lot of my
    # energy…". Every one of those is surfaced for a human to look at.
    class ArtPreview
      Row = Struct.new(
        :label, :image_id, :matched_label, :exact, :src, :original_url,
        :source_type, :license, :commercial_safe, :attribution_required, :share_alike,
        keyword_init: true,
      ) do
        def found? = image_id.present?

        def exact? = exact.present?

        # `src` is nil until the 288px variant is processed — that is not the
        # same as "no art". Fall back to the full-resolution original so the
        # review grid still shows a picture.
        def display_url = src.presence || original_url.presence
      end

      def initialize(labels:, commercial_safe_only: true)
        @labels = Array(labels).map { |label| label.to_s.strip }.reject(&:blank?)
        @commercial_safe_only = commercial_safe_only
      end

      def call
        rows = labels.map { |label| row_for(label) }

        {
          rows: rows,
          total: rows.size,
          found: rows.count(&:found?),
          coverage_pct: coverage_pct(rows),
          missing: rows.reject(&:found?).map(&:label),
          inexact: rows.select { |row| row.found? && !row.exact }.map(&:label),
          unsafe: rows.select { |row| row.found? && row.commercial_safe == false }.map(&:label),
        }
      end

      private

      attr_reader :labels, :commercial_safe_only

      def searcher
        # limit: 1 — the review grid shows what will actually be attached, not a
        # menu of alternatives. `resolve: true` prepends exactly that pick.
        @searcher ||= Images::LabelSearch.new(
          match: "exact",
          limit: 1,
          commercial_safe: commercial_safe_only,
          resolve: true,
        )
      end

      def row_for(label)
        result = searcher.call(label).first
        return Row.new(label: label, exact: false) if result.nil?

        Row.new(
          label: label,
          image_id: result[:id],
          matched_label: result[:label],
          exact: exact?(label, result[:label]),
          src: result[:src],
          original_url: result[:original_url],
          source_type: result[:source_type],
          license: result[:license],
          commercial_safe: result[:commercial_safe],
          attribution_required: result[:attribution_required],
          share_alike: result[:share_alike],
        )
      end

      # `images.label` is the lowercase matching key, so casing never makes a
      # match inexact — a different *word* does.
      def exact?(requested, matched)
        Boards::ImageResolver.normalize(requested) == Boards::ImageResolver.normalize(matched)
      end

      def coverage_pct(rows)
        return 0 if rows.empty?

        ((rows.count(&:found?) / rows.size.to_f) * 100).round
      end
    end
  end
end
