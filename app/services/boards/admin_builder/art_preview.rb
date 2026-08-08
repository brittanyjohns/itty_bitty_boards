module Boards
  module AdminBuilder
    # What the library would put on each tile across the whole set, resolved
    # WITHOUT WRITING ANYTHING.
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
        :links_to,
        keyword_init: true,
      ) do
        def found? = image_id.present?

        def exact? = exact.present?

        def folder? = links_to.present?

        # `src` is nil until the 288px variant is processed — that is not the
        # same as "no art". Fall back to the full-resolution original so the
        # review grid still shows a picture.
        def display_url = src.presence || original_url.presence
      end

      def initialize(pages:, commercial_safe_only: true)
        @pages = Array(pages)
        @commercial_safe_only = commercial_safe_only
      end

      def call
        previewed = pages.map do |page|
          # `columns`/`tile_count` carry the page's OWN grid through to the view:
          # with mixed grids a page needn't match the main board, so the review
          # grid can't be drawn from the form's top-level columns.
          {
            key: page[:key],
            name: page[:name],
            columns: page[:columns].to_i,
            tile_count: page[:tile_count].to_i,
            rows: page[:tiles].map { |tile| row_for(tile) },
          }
        end

        # Coverage is over distinct labels: the same word on two pages is one
        # symbol and one generation, so counting it twice would misreport both
        # the percentage and the AI spend.
        distinct = previewed.flat_map { |page| page[:rows] }.uniq { |row| row.label.downcase }

        {
          pages: previewed,
          total: distinct.size,
          found: distinct.count(&:found?),
          coverage_pct: coverage_pct(distinct),
          missing: distinct.reject(&:found?).map(&:label),
          inexact: distinct.select { |row| row.found? && !row.exact }.map(&:label),
          unsafe: distinct.select { |row| row.found? && row.commercial_safe == false }.map(&:label),
        }
      end

      private

      attr_reader :pages, :commercial_safe_only

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

      # A label repeated across pages costs one search, not one per page.
      def lookup(label)
        @lookup ||= {}
        key = label.downcase
        return @lookup[key] if @lookup.key?(key)

        @lookup[key] = searcher.call(label).first
      end

      def row_for(tile)
        label = tile[:label].to_s.strip
        result = lookup(label)
        return Row.new(label: label, exact: false, links_to: tile[:links_to]) if result.nil?

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
          links_to: tile[:links_to],
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
