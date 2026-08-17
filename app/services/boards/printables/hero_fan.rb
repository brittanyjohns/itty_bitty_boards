# The geometry of the overlapping pile of pages on the hero slide.
#
# Pure arithmetic, no I/O, so the one rule that matters here is testable without
# standing up Grover: n cards of width W overlapping by V occupy `nW - (n-1)V`
# of the stage, and anything over ~98% runs the outer pages off the slide edge.
# `.build` raises rather than returning an overflowing plan, because the failure
# mode otherwise is a listing image that looks fine in the admin thumbnail and
# has half a page missing at full size.
#
# This exists as a class rather than a table in the layout's CSS because the
# layout used to hold an `nth-child(1)/(2)/(3)` ladder — correct for exactly
# three cards, and silently wrong the moment HERO_TILES moved. The values are
# emitted as inline custom properties instead, so the CSS never has to know how
# many cards there are.
module Boards
  module Printables
    class HeroFan
      # Card width and overlap as percentages of the stage, per card count.
      # Each row satisfies the closing rule above with a little slack:
      #   2 -> 100 - 12 = 88    3 -> 120 - 22 = 98
      #   4 -> 136 - 38 = 98    5 -> 150 - 52 = 98
      GEOMETRY = {
        2 => {width: 50.0, overlap: 12.0},
        3 => {width: 40.0, overlap: 11.0},
        4 => {width: 34.0, overlap: 12.67},
        5 => {width: 30.0, overlap: 13.0},
      }.freeze

      # The stage is 960px wide after the safe zone, so past five cards each one
      # is under 290px and a board page at that size is a coloured smudge — the
      # buyer can count the pages but can't read a word, which is the failure the
      # fan exists to avoid. The what's-included slide is where the full set is
      # counted.
      MAX_CARDS = GEOMETRY.keys.max

      # Total tilt across the pile. Spread over however many cards there are, so
      # two cards splay gently and five splay hard enough to read as a stack.
      TOTAL_ROTATION_DEG = 14.0

      # The closing rule. 100 would touch the edge exactly; the cards are
      # rotated, so their corners need somewhere to go.
      MAX_COVERAGE = 98.0

      Card = Struct.new(:rotation_deg, :z_index, keyword_init: true)

      class OverflowError < StandardError; end

      attr_reader :count, :width, :overlap, :cards

      def self.build(count)
        new(count)
      end

      def initialize(count)
        @count = count.to_i
        raise ArgumentError, "HeroFan needs at least two cards; #{count} is a single page" if @count < 2

        if @count > MAX_CARDS
          raise ArgumentError, "HeroFan has no geometry for #{@count} cards (max #{MAX_CARDS})"
        end

        geometry = GEOMETRY.fetch(@count)
        @width = geometry[:width]
        @overlap = geometry[:overlap]
        assert_closes!
        @cards = build_cards
      end

      def css_width = format("%.2f%%", width)

      def css_overlap = format("%.2f%%", overlap)

      # What the cards actually occupy, as a percentage of the stage.
      def coverage = (count * width) - ((count - 1) * overlap)

      private

      def assert_closes!
        return if coverage <= MAX_COVERAGE

        raise OverflowError,
              "#{count} cards at #{width}% overlapping #{overlap}% cover #{coverage.round(2)}% " \
              "of the stage; anything over #{MAX_COVERAGE}% runs the outer pages off the slide."
      end

      # The centre card is drawn in front and unrotated — it is the one the
      # buyer actually reads, and RenderListingImages puts the ROOT board there.
      # z-index descends outward from it so the pile reads as a pile rather than
      # a staircase.
      def build_cards
        centre = (count - 1) / 2.0
        step = TOTAL_ROTATION_DEG / (count - 1)

        Array.new(count) do |index|
          offset = index - centre
          Card.new(
            rotation_deg: (offset * step).round(2),
            z_index: count - offset.abs.ceil.to_i,
          )
        end
      end
    end
  end
end
