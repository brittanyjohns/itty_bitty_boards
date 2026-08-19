# The photographed tablets a board is warped onto for the "on a device" slides.
#
# The geometry lives in MockupScene; this file is only the list. See that class
# for why the quads below are copied rather than re-measured.
module Boards
  module Printables
    module TabletScene
      SALT = "tablet".freeze

      # The SLUGS are load-bearing; the order is not. StablePick scores each
      # entry by its own slug rather than its index, so this list can be
      # reordered or appended to freely — renaming a slug is what re-skins the
      # boards that had picked it. See StablePick for why that replaced the
      # modulo pick this (and BrandAssets::SCENES, and Palette::PALETTES) used
      # to do.
      SCENES = [
        {
          slug: "hands-tablet",
          kind: MockupScene::KIND_TABLET,
          width: 1536,
          height: 1024,
          # Clockwise from top-left, in scene-JPG pixels.
          quad: [[368, 242], [1152, 242], [1156, 766], [360, 764]],
        },
        {
          slug: "couch-lap-tablet",
          kind: MockupScene::KIND_TABLET,
          width: 1536,
          height: 1024,
          quad: [[366, 238], [1134, 236], [1150, 742], [350, 742]],
        },
        # The two below are photographs of real tablets, exported from Canva
        # mockups. Their quads were fitted by WARPING A BLOCK ONTO THEM AND
        # LOOKING — drawing the quad flat on the photo is not good enough, and
        # was wrong by 20-40px here: the warp composes the quad with the
        # cover-placement transform, and an error invisible on the flat photo is
        # obvious once the board is on the glass.
        #
        # Both come out at 4:3, which is the check that the numbers are right —
        # that is the shape of a real iPad screen. The two generated scenes
        # above are 1.50 and 1.55, so no single shell fits all four, which is
        # why RenderDeviceScreen sizes itself from the scene.
        #
        # Both quads sit a few pixels PROUD of the glass, deliberately. Each
        # photo's screen already shows something — a board in one, a landscape
        # wallpaper in the other — and a quad fitted flush leaves a sliver of it
        # along an edge, which reads as a rendering fault. Bleeding onto the
        # bezel reads as the edge of the screen.
        {
          slug: "desk-tablet-tap",
          kind: MockupScene::KIND_TABLET,
          width: 1536,
          height: 1086,
          quad: [[612, 158], [1356, 424], [1152, 975], [415, 724]],
        },
        {
          slug: "table-tablet-talk",
          kind: MockupScene::KIND_TABLET,
          width: 1536,
          height: 864,
          quad: [[602, 229], [972, 365], [876, 652], [442, 528]],
        },
      ].freeze

      class << self
        def for(board) = MockupScene.new(scene_for(board))

        def scene_for(board)
          StablePick.from(SCENES, salt: SALT, board: board, slug_for: ->(s) { s[:slug] })
        end

        # The gallery shows a board on a tablet twice, and the two must not be
        # the same photograph — that reads as one screenshot pasted twice rather
        # than a product someone actually uses.
        def pair_for(board)
          StablePick.top(SCENES, 2, salt: SALT, board: board, slug_for: ->(s) { s[:slug] })
                    .map { |values| MockupScene.new(values) }
        end
      end
    end
  end
end
