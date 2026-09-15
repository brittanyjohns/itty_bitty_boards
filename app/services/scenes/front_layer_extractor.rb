module Scenes
  # Builds a template's FRONT LAYER from a magenta-marked scene: a transparent
  # PNG, the same size as the scene, holding everything that sits in front of
  # the art.
  #
  # Only the area the art will cover is considered — each slot's quad pushed out
  # by its bleed_px (the footprint RenderSceneComposition warps into), plus
  # OVERLAP_PX so the art's antialiased rim is covered too.
  # Inside that footprint:
  #
  # - a pixel that isn't magenta at all (a clip, a magnet, a thumb over the
  #   sheet, or the fridge beside an edge the quad overshoots) is copied OPAQUE;
  # - a fully magenta pixel is TRANSPARENT, so the art shows;
  # - a partial pixel (the antialiased edge) gets alpha = 1 - score, with the
  #   magenta spill taken out of its colour so the edge doesn't glow pink.
  #
  # Everything outside every footprint is transparent. The effect is that the
  # art is clipped to exactly where the magenta was, and anything that was
  # drawn over the placeholder stays over the art.
  class FrontLayerExtractor
    OPAQUE_AT_OR_BELOW = 0.02
    CLEAR_AT_OR_ABOVE = 0.98
    # The layer reaches this far PAST the art's footprint. Chrome antialiases
    # the warped art's edge while this layer's edge is decided per pixel centre,
    # so a layer that stops exactly at the footprint leaves a hairline of the
    # art's white rim showing (seen in a dev render through a magnet and along a
    # card's edge). Overlapping by a couple of pixels covers that rim with the
    # scene's own pixels, which are what the base shows there anyway.
    OVERLAP_PX = 2

    def initialize(image, slots, mask: nil)
      @image = image
      @slots = Array(slots)
      @mask = mask || MagentaMask.new(image)
    end

    def call
      layer = ChunkyPNG::Image.new(@image.width, @image.height, ChunkyPNG::Color::TRANSPARENT)
      @slots.each { |slot| paint_slot(layer, slot) }
      layer
    end

    # Removes a magenta cast while keeping the pixel's brightness: the amount
    # red and blue BOTH exceed green is the spill; it comes off red and blue,
    # and the lost luminance is added back evenly.
    def self.despill(r, g, b)
      spill = [r, b].min - g
      return [r, g, b] unless spill.positive?

      before = luminance(r, g, b)
      r2 = r - spill
      b2 = b - spill
      lift = before - luminance(r2, g, b2)
      [r2 + lift, g + lift, b2 + lift].map { |c| c.round.clamp(0, 255) }
    end

    def self.luminance(r, g, b) = (0.299 * r) + (0.587 * g) + (0.114 * b)

    private

    def paint_slot(layer, slot)
      geometry = Boards::Printables::SceneSlot.from_hash(slot)
      quad = Boards::Printables::SceneSlot.new(quad: geometry.quad, bleed_px: geometry.bleed_px + OVERLAP_PX).with_bleed.quad
      x0 = [quad.map(&:first).min.floor, 0].max
      x1 = [quad.map(&:first).max.ceil, @image.width - 1].min
      y0 = [quad.map(&:last).min.floor, 0].max
      y1 = [quad.map(&:last).max.ceil, @image.height - 1].min

      (y0..y1).each do |y|
        (x0..x1).each do |x|
          next unless inside?(quad, x + 0.5, y + 0.5)

          score = @mask.score_at(x, y)
          next if score >= CLEAR_AT_OR_ABOVE

          pixel = @image.get_pixel(x, y)
          if score <= OPAQUE_AT_OR_BELOW
            layer.set_pixel(x, y, pixel)
          else
            r, g, b = self.class.despill(ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel), ChunkyPNG::Color.b(pixel))
            alpha = ((1.0 - score) * ChunkyPNG::Color.a(pixel)).round
            layer.set_pixel(x, y, ChunkyPNG::Color.rgba(r, g, b, alpha))
          end
        end
      end
    end

    # Convex, clockwise in image coordinates: inside is to the right of every
    # edge, i.e. a non-negative cross product.
    def inside?(quad, px, py)
      4.times.all? do |i|
        ax, ay = quad[i]
        bx, by = quad[(i + 1) % 4]
        ((bx - ax) * (py - ay)) - ((by - ay) * (px - ax)) >= 0
      end
    end
  end
end
