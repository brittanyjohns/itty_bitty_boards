require "chunky_png"

module Scenes
  # How "placeholder magenta" a pixel is, from 0.0 (not at all) to 1.0.
  #
  # A scene marks every surface real art will be warped onto in flat magenta
  # (#FF00FF). A photo never delivers the exact value: the surface is shaded,
  # JPEG-ish noise creeps in, and its edges blend into whatever surrounds it. So
  # the score is a hue window around 300° with a saturation ramp, and brightness
  # doesn't matter — a magenta sheet in shadow still counts. The ramps give the
  # antialiased edge a PARTIAL score, which is what FrontLayerExtractor turns
  # into alpha.
  #
  # Pure Ruby over ChunkyPNG (a dependency we already ship via rqrcode). The
  # quick reject — magenta needs red AND blue above green — is what keeps a full
  # scan affordable, since almost every pixel in a scene fails it.
  class MagentaMask
    HUE_CENTER = 300.0
    # Full score within ±HUE_FULL of 300° (285-315), fading to 0 by ±HUE_ZERO.
    HUE_FULL = 15.0
    HUE_ZERO = 40.0
    # Saturation (chroma / max) at or above SAT_FULL scores fully; at or below
    # SAT_ZERO scores nothing. A 50/50 blend of magenta and white sits at 0.5.
    SAT_FULL = 0.7
    SAT_ZERO = 0.2
    # Below this brightness the hue of a pixel is noise.
    MIN_MAX_CHANNEL = 30
    MIN_CHROMA = 20

    # What "is a placeholder pixel" means for detection and for the inpaint mask.
    THRESHOLD = 0.5

    attr_reader :image

    def initialize(image)
      @image = image
      @memo = {}
    end

    def width = image.width
    def height = image.height

    # A photo has hundreds of thousands of distinct colours, so only colours
    # that pass the quick reject are memoized (a flat placeholder repeats a
    # handful of them), and the memo is dropped before it grows unbounded.
    MEMO_LIMIT = 100_000

    def score_at(x, y)
      pixel = image.get_pixel(x, y)
      g = (pixel >> 16) & 0xff
      return 0.0 if g >= (pixel >> 24) & 0xff || g >= (pixel >> 8) & 0xff

      @memo.clear if @memo.size > MEMO_LIMIT
      @memo[pixel] ||= self.class.score(pixel)
    end

    def magenta_at?(x, y) = score_at(x, y) >= THRESHOLD

    # A ChunkyPNG colour integer (0xRRGGBBAA) → 0.0..1.0. A transparent pixel
    # is never a placeholder.
    def self.score(pixel)
      return 0.0 if ChunkyPNG::Color.a(pixel) < 128

      score_rgb(ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel), ChunkyPNG::Color.b(pixel))
    end

    def self.score_rgb(r, g, b)
      return 0.0 if g >= r || g >= b

      max = r > b ? r : b
      chroma = max - g
      return 0.0 if max < MIN_MAX_CHANNEL || chroma < MIN_CHROMA

      # Green is the minimum here, so the hue sits in the 240°-360° sextants.
      hue = if r >= b
              360.0 - (60.0 * (b - g) / chroma)
            else
              240.0 + (60.0 * (r - g) / chroma)
            end
      hue_weight = ramp_down((hue - HUE_CENTER).abs, HUE_FULL, HUE_ZERO)
      return 0.0 if hue_weight.zero?

      sat_weight = ramp_up(chroma.to_f / max, SAT_ZERO, SAT_FULL)
      hue_weight * sat_weight
    end

    def self.ramp_up(value, zero, full)
      return 0.0 if value <= zero
      return 1.0 if value >= full

      (value - zero) / (full - zero)
    end

    def self.ramp_down(distance, full, zero)
      return 1.0 if distance <= full
      return 0.0 if distance >= zero

      1.0 - ((distance - full) / (zero - full))
    end
  end
end
