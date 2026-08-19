require "rails_helper"

RSpec.describe Boards::Printables::TabletScene do
  let(:owner) { create(:user) }

  def board(slug) = build(:board, user: owner, slug: slug)

  # Same rule as the room scenes and the palettes: a listing is live by the time
  # anyone regenerates it, and a random pick would re-skin it every time.
  it "picks the same tablet for a board every time" do
    picks = Array.new(5) { described_class.for(board("core-words")).slug }

    expect(picks.uniq.size).to eq(1)
  end

  it "spreads boards across the scenes it has" do
    slugs = Array.new(40) { |i| described_class.for(board("board-#{i}")).slug }

    expect(slugs.uniq).to match_array(described_class::SCENES.map { |s| s[:slug] })
  end

  # The gallery stages a board on a tablet TWICE, and two identical photographs
  # read as one screenshot pasted twice — which is the whole reason the second
  # slide exists.
  describe ".pair_for" do
    it "hands back two different tablets" do
      pair = described_class.pair_for(board("core-words"))

      expect(pair.size).to eq(2)
      expect(pair.map(&:slug).uniq.size).to eq(2)
    end

    it "leads with the same tablet .for picks, so the pair is an extension of it" do
      b = board("core-words")

      expect(described_class.pair_for(b).first.slug).to eq(described_class.for(b).slug)
    end

    it "picks the same pair every time" do
      pairs = Array.new(5) { described_class.pair_for(board("core-words")).map(&:slug) }

      expect(pairs.uniq.size).to eq(1)
    end
  end

  # A third thing hashed off the board, so it needs its own salt for the same
  # reason the palette does — otherwise scene, palette and tablet move together
  # and the rotation collapses.
  it "rotates independently of the room scene and the palette" do
    boards = Array.new(40) { |i| board("board-#{i}") }

    pairs = boards.map do |b|
      [Boards::Printables::BrandAssets.scene_name_for(b), described_class.for(b).slug]
    end

    expect(pairs.uniq.size).to be > described_class::SCENES.size
  end

  # Calibration is done by hand in the printables repo's
  # calibrate-mockup-scene.html and the numbers are copied here, so these are the
  # assertions that catch a bad paste before a listing does.
  describe "every vendored scene" do
    described_class::SCENES.each do |values|
      context values[:slug] do
        subject(:scene) { Boards::Printables::MockupScene.new(values) }

        it "has its photo on disk" do
          expect(scene.data_uri).to start_with("data:image/jpeg;base64,")
        end

        it "keeps every quad corner inside the photo" do
          scene.quad.each do |x, y|
            expect(x).to be_between(0, values[:width])
            expect(y).to be_between(0, values[:height])
          end
        end

        it "solves to a matrix rather than a degenerate quad" do
          expect { scene.matrix3d }.not_to raise_error
        end

        # A homography maps ANY rectangle onto the quad, so a screen shaped
        # unlike the shell it receives doesn't fail — it silently ships a
        # stretched board, which a buyer reads as "the product is distorted".
        # RenderDeviceScreen sizes itself from the scene, so what has to hold is
        # that the two agree, and that the quad is a plausible landscape tablet
        # rather than a mis-clicked sliver.
        # Every scene is a landscape photo and the slide is square, so cover
        # throws away a quarter of the width — and no placeholder is centred in
        # its own photo. Centring the SCENE sliced the left edge off the fridge
        # sheet and ran the desk tablet off the right. Whatever is left outside
        # has to be left outside evenly, which reads as a close crop instead.
        it "keeps its placeholder centred in the square crop" do
          placement = scene.cover_placement(1280)
          xs = scene.quad.map { |x, _| (x * placement[:scale]) + placement[:offset_x] }

          expect([-xs.min, 0].max).to be_within(1).of([xs.max - 1280, 0].max)
          expect(xs.max - xs.min).to be > 0
        end

        it "gets an app shell shaped like its own screen" do
          screen = scene.target_width.to_f / scene.target_height
          shell = Boards::Printables::RenderDeviceScreen.new(title: "x", thumbnail: nil, scene: scene)

          expect(screen).to be_between(1.2, 1.8)
          expect(shell.shell_width.to_f / shell.shell_height).to be_within(0.02).of(screen)
        end
      end
    end
  end

  describe "the screen it warps onto" do
    subject(:scene) { described_class.for(board("core-words")) }

    # The board is letterboxed into a rectangle of the quad's own proportions. A
    # homography will map ANY rectangle onto the quad, so getting this wrong
    # doesn't fail — it silently stretches the board on the glass.
    #
    # Measured as EDGE LENGTH, not as the quad's width and height on the page.
    # Those agree only while a tablet is photographed square-on; for one held at
    # an angle the extents are much shorter than the edges, and sizing from them
    # would squash the board by exactly the amount the tablet is rotated.
    it "sizes the flat rectangle to the quad's own edges, not its extents" do
      described_class::SCENES.each do |values|
        scene = Boards::Printables::MockupScene.new(values)
        tl, tr, br, bl = scene.quad
        edge = ->(a, b) { Math.hypot(b[0] - a[0], b[1] - a[1]) }

        expect(scene.target_width).to be_within(1).of((edge.call(tl, tr) + edge.call(bl, br)) / 2)
        expect(scene.target_height).to be_within(1).of((edge.call(tl, bl) + edge.call(tr, br)) / 2)
      end
    end

    it "measures a rotated tablet's screen larger than its bounding box" do
      rotated = Boards::Printables::MockupScene.new(described_class::SCENES.find { |s| s[:slug] == "desk-tablet-tap" })
      tl, tr, = rotated.quad

      expect(rotated.target_width).to be > (tr[0] - tl[0])
    end

    it "warps that rectangle, not some other one" do
      expect(scene.matrix3d).to start_with("matrix3d(")
    end

    it "reads the photo off disk rather than over the network" do
      expect(scene.data_uri).to start_with("data:image/jpeg;base64,")
    end
  end

  describe "#cover_placement" do
    subject(:scene) { described_class.for(board("core-words")) }

    # The scene is cover-placed by hand, not by object-fit, because the screen
    # corners live in the photo's pixels — object-fit would move the photo
    # without telling anything where those corners went.
    it "scales the photo to cover the square slide and centres the overflow" do
      placement = scene.cover_placement(1280)

      expect(scene.width * placement[:scale]).to be >= 1280
      expect(scene.height * placement[:scale]).to be >= 1280 - 0.001
      expect(placement[:offset_x]).to be <= 0
      expect(placement[:offset_y]).to be <= 0
    end
  end

  it "renders without a photo rather than raising when the file is missing" do
    scene = Boards::Printables::MockupScene.new(slug: "nope", width: 100, height: 100,
      quad: [[0, 0], [10, 0], [10, 10], [0, 10]])

    expect(scene.data_uri).to be_nil
  end
end
