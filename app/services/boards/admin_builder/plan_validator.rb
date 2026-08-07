module Boards
  module AdminBuilder
    # Rejects the authoring mistakes that produce a sparse or broken board,
    # before anything is resolved or written. Returns an array of
    # human-readable problems; empty means the plan is safe to build.
    #
    # The tile-count rule is the reason the page exists. Rows are never stored
    # (`Board#rows_for_screen_size` derives them from the tiles), so a partial
    # final row doesn't shorten the board — it leaves conspicuous empty cells at
    # the right end of the last row, which reads as broken on a classroom TV.
    class PlanValidator
      def initialize(tiles:, columns:, rows:, allow_partial_row: false)
        @tiles = Array(tiles)
        @columns = columns.to_i
        @rows = rows.to_i
        @allow_partial_row = allow_partial_row
      end

      def call
        return ["Set both a column count and a row count."] if columns < 1 || rows < 1

        problems = []
        problems.concat(count_problems)
        problems.concat(label_problems)
        problems.concat(part_of_speech_problems)
        problems
      end

      private

      attr_reader :tiles, :columns, :rows, :allow_partial_row

      def cells = columns * rows

      def count_problems
        return ["Add at least one word."] if tiles.empty?

        # Overflow is always an error: there is no cell for the extra tiles, so
        # "allow a partial row" can't rescue it.
        if tiles.size > cells
          return ["#{tiles.size} words won't fit a #{columns}×#{rows} grid (#{cells} cells). " \
                  "Remove #{tiles.size - cells}."]
        end

        return [] if tiles.size == cells || allow_partial_row

        ["#{tiles.size} words for a #{columns}×#{rows} grid (needs exactly #{cells}). " \
         "Add #{cells - tiles.size}. A partial row leaves dead cells at the end of the last row — " \
         "tick “allow a partial row” if you meant it."]
      end

      def label_problems
        problems = []
        problems << "Every tile needs a word — one line is empty." if labels.any?(&:blank?)

        keys = labels.reject(&:blank?).map(&:downcase)
        dupes = keys.tally.select { |_, count| count > 1 }.keys.sort
        if dupes.any?
          problems << "Duplicate words: #{dupes.join(", ")}. Each one costs a cell and buys nothing."
        end

        problems
      end

      def part_of_speech_problems
        bad = tiles.filter_map do |tile|
          pos = tile[:part_of_speech].presence || tile["part_of_speech"].presence || "default"
          pos unless ColorHelper::PARTS_OF_SPEECH.include?(pos.to_s)
        end.uniq.sort

        return [] if bad.empty?

        ["Unknown part of speech: #{bad.join(", ")}. Use one of: #{ColorHelper::PARTS_OF_SPEECH.join(", ")}."]
      end

      def labels
        @labels ||= tiles.map { |tile| (tile[:label] || tile["label"]).to_s.strip }
      end
    end
  end
end
