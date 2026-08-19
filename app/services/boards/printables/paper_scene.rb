# The photographed rooms a PRINTED sheet is warped into for the "on paper"
# slides — the half of the mockup library that stages the product a buyer
# actually receives.
#
# The geometry lives in MockupScene; this file is only the list. See that class
# for why the quads below are copied rather than re-measured.
#
# Two things separate this list from TabletScene's:
#
#   ORIENTATION. A homography maps ANY rectangle onto the quad, so a landscape
#   board handed to a portrait clipboard does not fail — it silently stretches,
#   which a buyer reads as a distorted product. The pool is filtered by the
#   page's own orientation before anything is picked, and each half must stay
#   big enough for the two distinct picks the gallery needs (asserted in spec).
#
#   A WHITE BACKING. Every placeholder in these photos is a blank white sheet,
#   so the artwork element fills the whole quad in white and the page is
#   letterboxed inside it. The leftover margin reads as the sheet's own white
#   paper rather than as a gap where the mockup shows through — which is what
#   lets a 1.97-aspect quad like kid-table-crayons carry a 1.29-aspect Letter
#   page without either stretching it or exposing the placeholder.
module Boards
  module Printables
    module PaperScene
      SALT = "paper".freeze

      # Slugs are load-bearing, order is not — same rule as TabletScene::SCENES.
      SCENES = [
        {
          slug: "classroom-easel",
          kind: MockupScene::KIND_PAPER,
          orientation: :landscape,
          width: 1536,
          height: 1024,
          # Clockwise from top-left, in scene-JPG pixels.
          quad: [[290, 158], [1118, 170], [1172, 764], [320, 792]],
        },
        {
          slug: "kid-table-crayons",
          kind: MockupScene::KIND_PAPER,
          orientation: :landscape,
          width: 1536,
          height: 1024,
          quad: [[484, 257], [1262, 484], [1008, 852], [210, 545]],
        },
        {
          slug: "fridge-magnets",
          kind: MockupScene::KIND_PAPER,
          orientation: :landscape,
          width: 1536,
          height: 1024,
          quad: [[216, 178], [1008, 194], [1006, 776], [218, 802]],
        },
        {
          slug: "child-hand-pointing",
          kind: MockupScene::KIND_PAPER,
          orientation: :landscape,
          width: 1536,
          height: 1024,
          quad: [[224, 144], [1186, 146], [1188, 730], [226, 728]],
        },
        {
          slug: "clipboard-therapy",
          kind: MockupScene::KIND_PAPER,
          orientation: :portrait,
          width: 1536,
          height: 1024,
          quad: [[496, 182], [1028, 186], [954, 908], [406, 862]],
        },
        {
          slug: "laminated-binder",
          kind: MockupScene::KIND_PAPER,
          orientation: :portrait,
          width: 1536,
          height: 1024,
          quad: [[464, 108], [1168, 96], [1108, 912], [466, 854]],
        },
      ].freeze

      # The gallery shows two paper mockups, and they must not be the same room
      # twice. Both come out of one ranked pick so the pair is deterministic and
      # distinct; StablePick explains why that survives the list growing.
      MIN_POOL = 2

      class << self
        def pool_for(landscape:)
          SCENES.select { |s| (s[:orientation] == :portrait) != landscape }
        end

        def for(board, landscape: true) = pair_for(board, landscape: landscape).first

        def pair_for(board, landscape: true)
          pool = pool_for(landscape: landscape)
          StablePick.top(pool, MIN_POOL, salt: SALT, board: board, slug_for: ->(s) { s[:slug] })
                    .map { |values| MockupScene.new(values) }
        end
      end
    end
  end
end
