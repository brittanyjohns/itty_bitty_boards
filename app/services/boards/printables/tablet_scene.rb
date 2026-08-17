# The photographed tablet a board is warped onto for the "on a device" slide.
#
# Vendored from speakanyway-printables' calibrated scene library
# (src/plugins/aac/templates/assets/mockup-scenes/), which is where the photos
# were generated and where their screen corners were clicked out by hand in that
# repo's calibrate-mockup-scene.html. The quads below are those corners, in the
# JPG's own pixel space — copied, not re-measured. Re-deriving them by eye is
# how a board ends up floating a few pixels off the glass.
#
# Only the two `kind: "tablet"` board scenes are here. The pipeline's other
# seventeen scenes stage products this app doesn't make (ID cards, device tags,
# stickers, temporary tattoos) or warp a printed sheet onto furniture, which is
# the mockup compositing this app still deliberately leaves to that repo.
module Boards
  module Printables
    class TabletScene
      DIR = Rails.root.join("app/assets/images/printables/mockups").freeze

      # The SLUGS are load-bearing; the order is not. StablePick scores each
      # entry by its own slug rather than its index, so this list can be
      # reordered or appended to freely — renaming a slug is what re-skins the
      # boards that had picked it. See StablePick for why that replaced the
      # modulo pick this (and BrandAssets::SCENES, and Palette::PALETTES) used
      # to do.
      SCENES = [
        {
          slug: "hands-tablet",
          width: 1536,
          height: 1024,
          # Clockwise from top-left, in scene-JPG pixels.
          quad: [[368, 242], [1152, 242], [1156, 766], [360, 764]],
        },
        {
          slug: "couch-lap-tablet",
          width: 1536,
          height: 1024,
          quad: [[366, 238], [1134, 236], [1150, 742], [350, 742]],
        },
      ].freeze

      class << self
        def for(board) = new(scene_for(board))

        def scene_for(board)
          StablePick.from(SCENES, salt: "tablet", board: board, slug_for: ->(s) { s[:slug] })
        end
      end

      attr_reader :slug, :width, :height, :quad

      def initialize(values)
        @slug = values[:slug]
        @width = values[:width]
        @height = values[:height]
        @quad = values[:quad]
      end

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
      # => { scale:, offset_x:, offset_y: }
      def cover_placement(canvas_px)
        scale = [canvas_px.to_f / width, canvas_px.to_f / height].max

        {
          scale: scale,
          offset_x: (canvas_px - (width * scale)) / 2.0,
          offset_y: (canvas_px - (height * scale)) / 2.0,
        }
      end

      # The flat rectangle that gets warped onto the screen, sized to the quad's
      # own proportions — the average of its two horizontal edges and its two
      # vertical ones.
      #
      # The board is letterboxed inside THIS rather than being handed straight
      # to the homography at its own aspect. A homography maps a rectangle onto
      # the quad whatever its shape, so feeding it a portrait board would fit
      # the board to the screen by stretching it — a squashed board on a tablet
      # that a buyer reads as "the product is distorted".
      def screen_width
        tl, tr, br, bl = quad
        ((distance(tl, tr) + distance(bl, br)) / 2.0).round
      end

      def screen_height
        tl, tr, br, bl = quad
        ((distance(tl, bl) + distance(tr, br)) / 2.0).round
      end

      # The matrix3d that warps that rectangle onto the screen. Solved in the
      # SCENE's pixel space, which is also the space the stage lays out in, so
      # the maths never has to know how big the slide is.
      def matrix3d
        Homography.matrix3d(screen_width, screen_height, quad)
      end

      private

      def distance(a, b) = Math.hypot(b[0] - a[0], b[1] - a[1])
    end
  end
end
