# Pure layout planner for the what's-included slide's grid of board thumbnails.
#
# Port of the pipeline's src/generator/content-tiles.ts, keyed on boards rather
# than merged-PDF page numbers — Rails renders thumbnails from board HTML, so it
# never has to think in page offsets. The two rules that file exists for carry
# over unchanged:
#
#   1. Cap the tiles. A 20-board bundle laid out in one row rendered ~55px
#      hairlines nobody could read.
#   2. Keep low-ink pages out of the grid. They're pixel duplicates of the
#      colour pages, and interleaving them reads as the same board printed
#      twice. They get their own slide instead, so this plan is used once per
#      ink and never mixes the two.
#
# Pure: no I/O, no Grover, no ActiveRecord writes. Planning happens BEFORE any
# thumbnail is rendered so the renderer only pays for tiles that get shown.
module Boards
  module Printables
    class ContentTilePlan
      # Hard ceiling on tiles. 8 keeps each one legible at the slide's 1280px
      # width; past that the grid is decoration rather than information.
      MAX_TILES = 8

      Tile = Struct.new(:board, :label, keyword_init: true) do
        def board_id = board.id
      end

      attr_reader :tiles, :columns, :rows, :tile_max_px, :overflow_note

      def self.build(boards:, max_tiles: MAX_TILES)
        boards = Array(boards)
        shown = boards.first(max_tiles)
        columns = columns_for(shown.size)

        new(
          tiles: shown.map { |b| Tile.new(board: b, label: label_for(b)) },
          columns: columns,
          rows: rows_for(shown.size, columns),
          tile_max_px: tile_max_px_for(columns),
          overflow_note: overflow_note(boards.size - shown.size),
        )
      end

      # Blank names render no caption band at all rather than an empty one.
      def self.label_for(board)
        name = board.try(:name).to_s.strip
        return nil if name.empty?

        Etsy::CopyRules.title_case_words(name)
      end

      # <=3 stays one row so a small set gets large, readable tiles; 4-8 wraps
      # to two rows. Rows are always <= 2 by construction.
      def self.columns_for(count)
        return count if count <= 3
        return 2 if count <= 4
        return 3 if count <= 6

        4
      end

      # The grid needs DEFINITE row heights, not auto ones: the page cards size
      # themselves against the row, and a percentage measured against an
      # indefinite height resolves to nothing — which is what silently sliced
      # the bottom off every tile.
      def self.rows_for(count, columns)
        return 1 if count.zero? || columns.zero?

        (count / columns.to_f).ceil
      end

      # How wide a page card may get, in CSS px on the 1280px slide. The cards
      # are a uniform shape, so height follows from width — capping the width is
      # what stops a row of one or two boards growing taller than its slot,
      # without reaching for a percentage height the card can't resolve.
      def self.tile_max_px_for(columns)
        case columns
        when 0, 1 then 720
        when 2 then 520
        when 3 then 380
        else 300
        end
      end

      # Pages, not boards: each withheld board is one more page in the colour
      # PDF, and a buyer counts pages. Low-ink isn't counted here — it has a
      # slide of its own now rather than a mention in this caption.
      def self.overflow_note(withheld)
        return nil unless withheld.positive?

        noun = withheld == 1 ? "page" : "pages"
        "+#{withheld} more #{noun}"
      end

      private_class_method :label_for, :columns_for, :rows_for, :tile_max_px_for, :overflow_note

      def initialize(tiles:, columns:, rows:, tile_max_px:, overflow_note:)
        @tiles = tiles
        @columns = columns
        @rows = rows
        @tile_max_px = tile_max_px
        @overflow_note = overflow_note
      end

      def labels? = tiles.any? { |t| t.label.present? }
      def boards = tiles.map(&:board)
      def any? = tiles.any?
    end
  end
end
