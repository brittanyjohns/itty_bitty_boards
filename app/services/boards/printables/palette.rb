# Which set of brand colours a printable's listing slides are skinned in.
#
# Without this every listing in the shop is the same four images with different
# board art in the middle, and a buyer scrolling a search grid reads them as one
# product photographed repeatedly. Rotating the accent, the footer band and the
# background gives each listing its own look while keeping all of it on brand —
# every value here is already a token in layouts/listing_image.html.erb.
#
# Two rules, both load-bearing:
#
#   1. The pick is DETERMINISTIC and hashed from the board, never random. A
#      listing is already live by the time anyone re-renders it, and a random
#      pick would re-skin a published Etsy listing on every regeneration. Same
#      reasoning as BrandAssets::SCENES, and PALETTES is ordered for the same
#      reason: reordering it re-skins every existing listing.
#   2. The salt differs from the scene pick, so palette and room photo rotate
#      INDEPENDENTLY. Hashing the same key twice would pair scene 1 with palette
#      1 forever and collapse 4 x 5 looks back down to 4.
#
# What a palette may NOT touch: the navy title banner, the white paper cards,
# the black instant-download ribbon, and the navy-on-white QR. Those carry the
# contrast on every slide, and a palette that can move them is a palette that
# can ship an unreadable listing image.
module Boards
  module Printables
    class Palette
      # accent      — bullets, step numbers, badges, the founder greeting
      # accent_soft — the same job on a dark panel, so it has to stay light
      # band        — the footer strip; navy text sits on it, so it stays light
      # surface     — the non-hero slide background
      PALETTES = [
        {
          key: "purple-green",
          accent: "#5b2a86",
          accent_soft: "#c9f08a",
          band: "#c9f08a",
          surface: "linear-gradient(180deg, #b9e2ff 0%, #dff0ff 60%, #f7fbff 100%)",
        },
        {
          key: "blue-cyan",
          accent: "#0163aa",
          accent_soft: "#4ECDE6",
          band: "#4ECDE6",
          surface: "linear-gradient(180deg, #ffe9cf 0%, #fff6ea 60%, #fffdfa 100%)",
        },
        {
          key: "magenta-mint",
          accent: "#C857E8",
          accent_soft: "#c9f08a",
          band: "#b7edd0",
          surface: "linear-gradient(180deg, #ffe1f4 0%, #fbeeff 60%, #fffafd 100%)",
        },
        {
          key: "navy-sky",
          accent: "#13496f",
          accent_soft: "#79b8ec",
          band: "#a9d8f5",
          surface: "linear-gradient(180deg, #e6dcf7 0%, #f3edfb 60%, #fbf9ff 100%)",
        },
        {
          key: "plum-peach",
          accent: "#7a2e6d",
          accent_soft: "#ffd9b0",
          band: "#ffd9b0",
          surface: "linear-gradient(180deg, #d8f6e4 0%, #eefbf3 60%, #fbfffd 100%)",
        },
      ].freeze

      class << self
        def for(board) = new(PALETTES[index_for(board)])

        def index_for(board)
          key = board.try(:slug).presence || board.try(:id).to_s
          Digest::SHA256.hexdigest("palette:#{key}").to_i(16) % PALETTES.size
        end
      end

      attr_reader :key, :accent, :accent_soft, :band, :surface

      def initialize(values)
        @key = values[:key]
        @accent = values[:accent]
        @accent_soft = values[:accent_soft]
        @band = values[:band]
        @surface = values[:surface]
      end

      # Emitted into the layout right after the base :root, so it wins on
      # cascade order without any of the rules below it knowing a palette
      # exists — they all read the tokens.
      def css_vars
        <<~CSS
          :root {
            --accent: #{accent};
            --accent-soft: #{accent_soft};
            --band: #{band};
            --surface: #{surface};
          }
        CSS
      end
    end
  end
end
