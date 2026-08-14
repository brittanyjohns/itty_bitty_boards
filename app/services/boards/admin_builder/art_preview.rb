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
      # How many library results to offer per label. One is what gets attached;
      # the rest are what the admin can swap to on the review screen. Kept small
      # on purpose — the point is "is there a better picture for this word",
      # not a browsable library.
      CANDIDATE_LIMIT = 6

      # One alternative picture the admin may pin to a tile instead of the
      # library's pick. `doc_id` is what gets submitted and stored: an image id
      # would be ambiguous, since which doc an image resolves to moves as art
      # is added to it.
      Candidate = Struct.new(:doc_id, :image_id, :label, :url, :exact, keyword_init: true)

      Row = Struct.new(
        :label, :image_id, :doc_id, :matched_label, :exact, :src, :original_url,
        :source_type, :license, :commercial_safe, :attribution_required, :share_alike,
        :links_to, :alternatives,
        keyword_init: true,
      ) do
        def found? = image_id.present?

        def alternatives = self[:alternatives] || []

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
        # The review grid is drawn in GRID order, not authored order, because
        # BackTileAlignment moves each page's back tile into the cell its
        # parent's folder tile occupies. Previewing the authored order would
        # show the admin a layout the build isn't going to produce.
        cells = BackTileAlignment.cell_indexes(pages)

        previewed = pages.map do |page|
          # `columns`/`tile_count` carry the page's OWN grid through to the view:
          # with mixed grids a page needn't match the main board, so the review
          # grid can't be drawn from the form's top-level columns.
          {
            key: page[:key],
            name: page[:name],
            columns: page[:columns].to_i,
            tile_count: page[:tile_count].to_i,
            rows: in_grid_order(page[:tiles], cells[page[:key]]).map { |tile| row_for(tile) },
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

      # `cells[i]` is the cell tile `i` lands in; the grid reads the inverse.
      # Any tile the permutation doesn't cover keeps its authored slot, so a
      # missing or short array degrades to plain reading order.
      def in_grid_order(tiles, cells)
        return tiles if cells.blank?

        ordered = Array.new(tiles.size)
        leftover = []
        tiles.each_with_index do |tile, index|
          cell = cells[index]
          if cell.is_a?(Integer) && ordered[cell].nil?
            ordered[cell] = tile
          else
            leftover << tile
          end
        end
        ordered.map { |tile| tile || leftover.shift }.compact
      end

      def searcher
        # `resolve: true` puts what will ACTUALLY be attached first; everything
        # after it is an alternative the admin can pin instead. The tiers are
        # lazy, so asking for CANDIDATE_LIMIT still costs one lookup when the
        # first tier fills it.
        @searcher ||= Images::LabelSearch.new(
          match: "exact",
          limit: CANDIDATE_LIMIT,
          commercial_safe: commercial_safe_only,
          resolve: true,
        )
      end

      # A label repeated across pages costs one search, not one per page.
      def lookup(label)
        @lookup ||= {}
        key = label.downcase
        return @lookup[key] if @lookup.key?(key)

        @lookup[key] = searcher.call(label)
      end

      def row_for(tile)
        label = tile[:label].to_s.strip
        results = lookup(label)
        result = results.first
        return Row.new(label: label, exact: false, links_to: tile[:links_to]) if result.nil?

        Row.new(
          label: label,
          image_id: result[:id],
          doc_id: result[:doc_id],
          alternatives: candidates_for(label, results),
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

      # Every result the admin could pin, the library's own pick included, so
      # the picker can offer a way back to the default. Rows with no processed
      # thumbnail AND no original are dropped — an option with nothing to show
      # is not a choice.
      def candidates_for(label, results)
        results.filter_map do |result|
          url = result[:src].presence || result[:original_url].presence
          next if url.blank? || result[:doc_id].blank?

          Candidate.new(
            doc_id: result[:doc_id],
            image_id: result[:id],
            label: result[:label],
            url: url,
            exact: exact?(label, result[:label]),
          )
        end
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
