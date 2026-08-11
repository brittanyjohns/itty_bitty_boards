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
#      colour pages; they belong in the caption, where they read as more value
#      instead of as the same board printed twice.
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

      attr_reader :tiles, :columns, :overflow_note

      # low_ink_count defaults to one low-ink page per board because that is
      # what CollectPages always emits — every board is rendered twice, colour
      # then low-ink. It stays a parameter so the caption logic is testable
      # without standing up a printable.
      def self.build(boards:, max_tiles: MAX_TILES, low_ink_count: nil)
        boards = Array(boards)
        low_ink_count ||= boards.size
        shown = boards.first(max_tiles)

        new(
          tiles: shown.map { |b| Tile.new(board: b, label: label_for(b)) },
          columns: columns_for(shown.size),
          overflow_note: overflow_note(boards.size - shown.size, low_ink_count),
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

      def self.overflow_note(withheld, low_ink_count)
        hidden = withheld + low_ink_count
        return nil if hidden.zero?
        return "Plus a low-ink version of every page" if withheld.zero?

        noun = hidden == 1 ? "page" : "pages"
        return "+#{hidden} more #{noun}, including a low-ink version of every board" if low_ink_count.positive?

        "+#{hidden} more #{noun}"
      end

      private_class_method :label_for, :columns_for, :overflow_note

      def initialize(tiles:, columns:, overflow_note:)
        @tiles = tiles
        @columns = columns
        @overflow_note = overflow_note
      end

      def labels? = tiles.any? { |t| t.label.present? }
      def boards = tiles.map(&:board)
      def any? = tiles.any?
    end
  end
end
