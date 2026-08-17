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
        subject(:scene) { described_class.new(values) }

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
        # unlike the app shell doesn't fail — it silently ships a stretched
        # board, which a buyer reads as "the product is distorted".
        # RenderDeviceScreen's shell is one fixed size for every scene, so the
        # constraint lands here: keep new scenes near it, or teach that class to
        # size itself from scene.screen_width / scene.screen_height.
        it "has a screen shaped like the app shell it receives" do
          shell = Boards::Printables::RenderDeviceScreen::SHELL_WIDTH.to_f /
                  Boards::Printables::RenderDeviceScreen::SHELL_HEIGHT

          expect(scene.screen_width.to_f / scene.screen_height).to be_within(0.06).of(shell)
        end
      end
    end
  end

  describe "the screen it warps onto" do
    subject(:scene) { described_class.for(board("core-words")) }

    # The board is letterboxed into a rectangle of the quad's own proportions. A
    # homography will map ANY rectangle onto the quad, so getting this wrong
    # doesn't fail — it silently stretches the board on the glass.
    it "sizes the flat rectangle to the quad's own proportions" do
      tl, tr, br, bl = scene.quad
      expect(scene.screen_width).to be_within(2).of((tr[0] - tl[0] + br[0] - bl[0]) / 2)
      expect(scene.screen_height).to be_within(2).of((bl[1] - tl[1] + br[1] - tr[1]) / 2)
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
    scene = described_class.new(slug: "nope", width: 100, height: 100,
                                quad: [[0, 0], [10, 0], [10, 10], [0, 10]])

    expect(scene.data_uri).to be_nil
  end
end
