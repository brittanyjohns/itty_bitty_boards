# One calibrated placeholder in a scene photo: the four corners real artwork is
# warped onto, plus how that artwork is finished.
#
# Extracted from MockupScene so the vendored single-quad scenes (TabletScene,
# PaperScene) and the multi-slot SceneTemplate library share ONE copy of the
# quad maths. MockupScene delegates to this; its specs pin the numbers, and
# scene_slot_spec asserts the two agree for every vendored scene.
#
# The quad is in the BASE IMAGE's own pixel space, clockwise from top-left.
module Boards
  module Printables
    class SceneSlot
      KINDS = %w[paper tablet frame clipboard stack tag].freeze
      ORIENTATIONS = %w[portrait landscape any].freeze
      # Every art source a slot can be calibrated to take. Which of these an
      # OWNER may use is SceneComposition::SOURCES_FOR_OWNER's call, not the
      # slot's: a board printable has no product artwork, a product no boards.
      ACCEPTS = %w[page_thumbnail device_screen upload product_artwork].freeze
      FINISHES = %w[shadow glare none].freeze

      # The finish a slot gets when calibration didn't pick one: a screen reads
      # as lit, everything else reads as an object sitting on something.
      DEFAULT_FINISH_BY_KIND = Hash.new("shadow").merge("tablet" => "glare").freeze

      MAX_BLEED_PX = 20

      attr_reader :key, :label, :kind, :quad, :orientation, :accepts, :finish, :bleed_px

      # A slot hash as stored in scene_templates.slots (string or symbol keys).
      def self.from_hash(hash)
        h = hash.to_h.transform_keys(&:to_s)
        new(
          key: h["key"],
          label: h["label"],
          kind: h["kind"],
          quad: h["quad"],
          orientation: h["orientation"],
          accepts: h["accepts"],
          finish: h["finish"],
          bleed_px: h["bleed_px"],
        )
      end

      def initialize(quad:, key: nil, label: nil, kind: nil, orientation: nil, accepts: nil, finish: nil, bleed_px: 0)
        @key = key
        @label = label
        @kind = kind
        @quad = quad
        @orientation = orientation
        @accepts = Array(accepts)
        @finish = finish
        @bleed_px = bleed_px.to_f
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

      def aspect
        return nil unless target_height.positive?

        target_width.to_f / target_height
      end

      # What the quad's own shape says, independent of what calibration claims.
      def quad_landscape? = aspect.to_f > 1

      # The matrix3d that warps that rectangle onto the placeholder, solved in
      # the base image's pixel space — the space the stage lays out in — so the
      # maths never has to know how big the output is.
      def matrix3d
        Homography.matrix3d(target_width, target_height, quad)
      end

      # The same slot with its quad pushed outward by bleed_px, so the art runs a
      # few pixels proud of the placeholder's edge. A flush quad leaves a sliver
      # of whatever the photo drew there; bleeding reads as the surface's edge.
      # Each corner moves away from the centroid, which keeps the shape.
      def with_bleed
        return self unless bleed_px.positive?

        cx = quad.sum { |x, _| x.to_f } / 4
        cy = quad.sum { |_, y| y.to_f } / 4
        grown = quad.map do |x, y|
          dx = x - cx
          dy = y - cy
          length = Math.hypot(dx, dy)
          next [x, y] if length.zero?

          [(x + (dx / length * bleed_px)).round(2), (y + (dy / length * bleed_px)).round(2)]
        end

        self.class.new(key: key, label: label, kind: kind, quad: grown, orientation: orientation,
                       accepts: accepts, finish: finish, bleed_px: 0)
      end

      # Convex AND clockwise (in image coordinates, y down). A bow-tie quad
      # solves to a perfectly valid homography and renders the art folded over
      # itself; a counter-clockwise one renders it mirrored. Neither raises, so
      # both have to be refused by shape.
      def clockwise_convex?
        4.times.all? do |i|
          a = quad[i]
          b = quad[(i + 1) % 4]
          c = quad[(i + 2) % 4]
          cross = ((b[0] - a[0]) * (c[1] - b[1])) - ((b[1] - a[1]) * (c[0] - b[0]))
          cross.positive?
        end
      end

      def degenerate?
        return true unless target_width.positive? && target_height.positive?

        Homography.solve(target_width, target_height, quad)
        false
      rescue Homography::DegenerateQuadError, ArgumentError
        true
      end

      private

      def distance(a, b) = Math.hypot(b[0] - a[0], b[1] - a[1])
    end
  end
end
