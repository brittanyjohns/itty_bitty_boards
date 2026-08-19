# One photographed scene a board render is warped into, and all the geometry the
# warp needs.
#
# The scenes themselves are vendored from speakanyway-printables' calibrated
# library (src/plugins/aac/templates/assets/mockup-scenes/), which is where the
# photos were generated and where the placeholder corners were clicked out by
# hand in that repo's calibrate-mockup-scene.html. The quads in TabletScene and
# PaperScene are those corners, in each JPG's own pixel space — copied, not
# re-measured. Re-deriving them by eye is how a board ends up floating a few
# pixels off the glass, or off the paper.
#
# Two kinds, and the difference is only how the artwork is finished in CSS:
#
#   tablet — the app, on the glass. A faint diagonal glare sells it as a screen.
#   paper  — the printed sheet, in a room. A drop shadow sells it as an object
#            sitting on something.
#
# Everything else — cover placement, the letterboxing rectangle, the homography —
# is identical, which is why both lists share this class rather than each
# carrying their own copy of the maths.
module Boards
  module Printables
    class MockupScene
      DIR = Rails.root.join("app/assets/images/printables/mockups").freeze

      KIND_TABLET = "tablet".freeze
      KIND_PAPER = "paper".freeze

      attr_reader :slug, :kind, :width, :height, :quad, :orientation

      def initialize(values)
        @slug = values[:slug]
        @kind = values[:kind]
        @width = values[:width]
        @height = values[:height]
        @quad = values[:quad]
        @orientation = values[:orientation] || :landscape
      end

      def landscape? = orientation != :portrait

      # nil rather than raising, same as BrandAssets: a gallery that renders
      # plainer than intended beats a printable that can't render one at all.
      def data_uri
        path = DIR.join("#{slug}.jpg")
        return nil unless File.exist?(path)

        "data:image/jpeg;base64,#{Base64.strict_encode64(path.binread)}"
      end

      # The scene is placed at its own pixel size and scaled to cover the square
      # slide, so the quad — which is in those pixels — stays in lockstep with
      # what is actually on screen. Computing the cover placement here rather
      # than leaning on `object-fit: cover` is the whole point: object-fit moves
      # the image without telling CSS where the corners went.
      #
      # It centres the QUAD, not the photo. Every scene is a 3:2-ish landscape
      # and the slide is square, so cover throws away a quarter of the width —
      # and the placeholders are not centred in their photos. Centring the scene
      # sliced the left edge off the fridge sheet and ran the desk tablet off the
      # right, both of which read as a rendering fault rather than as a crop. The
      # offsets are then clamped so the photo still covers the canvas, and a quad
      # too wide to fit at all is cropped evenly on both sides, which reads as a
      # deliberate close-up.
      #
      # => { scale:, offset_x:, offset_y: }
      def cover_placement(canvas_px)
        scale = [canvas_px.to_f / width, canvas_px.to_f / height].max

        {
          scale: scale,
          offset_x: axis_offset(canvas_px, scale, width, quad.map(&:first)),
          offset_y: axis_offset(canvas_px, scale, height, quad.map(&:last)),
        }
      end

      # The flat rectangle that gets warped onto the placeholder, sized to the
      # quad's own proportions — the average of its two horizontal edges and its
      # two vertical ones.
      #
      # The artwork is letterboxed inside THIS rather than being handed straight
      # to the homography at its own aspect. A homography maps a rectangle onto
      # the quad whatever its shape, so feeding it a portrait board would fit the
      # board to the placeholder by stretching it — a squashed board that a buyer
      # reads as "the product is distorted".
      def target_width
        tl, tr, br, bl = quad
        ((distance(tl, tr) + distance(bl, br)) / 2.0).round
      end

      def target_height
        tl, tr, br, bl = quad
        ((distance(tl, bl) + distance(tr, br)) / 2.0).round
      end

      # The matrix3d that warps that rectangle onto the placeholder. Solved in
      # the SCENE's pixel space, which is also the space the stage lays out in,
      # so the maths never has to know how big the slide is.
      def matrix3d
        Homography.matrix3d(target_width, target_height, quad)
      end

      private

      # Slide the scene so the quad's midpoint lands on the canvas midpoint,
      # then clamp to the range where the photo still reaches both edges.
      def axis_offset(canvas_px, scale, extent, coords)
        midpoint = ((coords.min + coords.max) / 2.0) * scale
        centred = (canvas_px / 2.0) - midpoint

        centred.clamp(canvas_px - (extent * scale), 0.0)
      end

      def distance(a, b) = Math.hypot(b[0] - a[0], b[1] - a[1])
    end
  end
end
