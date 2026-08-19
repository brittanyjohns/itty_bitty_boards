require "rails_helper"

RSpec.describe Boards::Printables::PaperScene do
  let(:owner) { create(:user) }

  def board(slug) = build(:board, user: owner, slug: slug)

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

        it "is a paper scene, so it gets the drop shadow and not the screen glare" do
          expect(scene.kind).to eq(Boards::Printables::MockupScene::KIND_PAPER)
        end

        # The declared orientation is what filters the pool, and the quad is
        # what the page is actually warped onto. If the two disagree the filter
        # is a lie and a landscape board lands on a portrait sheet — which does
        # not fail, it silently stretches.
        it "has a quad shaped the way its orientation claims" do
          ratio = scene.target_width.to_f / scene.target_height

          expect(ratio > 1).to eq(scene.landscape?)
        end
      end
    end
  end

  # The pools are what make orientation filtering safe, and each has to stay big
  # enough for the two DISTINCT scenes the gallery asks for. Deleting a scene is
  # the change that quietly breaks this, which is why the number is asserted
  # rather than left to whoever edits SCENES next.
  describe ".pool_for" do
    it "has at least a pair for a landscape page" do
      expect(described_class.pool_for(landscape: true).size).to be >= described_class::MIN_POOL
    end

    it "has at least a pair for a portrait page" do
      expect(described_class.pool_for(landscape: false).size).to be >= described_class::MIN_POOL
    end

    it "never offers a portrait room to a landscape page" do
      expect(described_class.pool_for(landscape: true).map { |s| s[:orientation] }.uniq).to eq([:landscape])
    end

    it "never offers a landscape room to a portrait page" do
      expect(described_class.pool_for(landscape: false).map { |s| s[:orientation] }.uniq).to eq([:portrait])
    end

    # Disjoint pools are what make a mixed-orientation set safe without a second
    # pick having to know what the first one took.
    it "shares no scene between the two pools" do
      landscape = described_class.pool_for(landscape: true).map { |s| s[:slug] }
      portrait = described_class.pool_for(landscape: false).map { |s| s[:slug] }

      expect(landscape & portrait).to be_empty
    end
  end

  describe ".pair_for" do
    it "hands back two different rooms" do
      pair = described_class.pair_for(board("core-words"))

      expect(pair.size).to eq(2)
      expect(pair.map(&:slug).uniq.size).to eq(2)
    end

    # Same rule as the tablets, the room scenes and the palettes: a listing is
    # live by the time anyone regenerates it, and a random pick would re-skin it.
    it "picks the same pair every time" do
      pairs = Array.new(5) { described_class.pair_for(board("core-words")).map(&:slug) }

      expect(pairs.uniq.size).to eq(1)
    end

    it "stays inside the pool the page's orientation allows" do
      pair = described_class.pair_for(board("tall-board"), landscape: false)

      expect(pair.map(&:landscape?)).to all(be(false))
    end

    it "spreads boards across the landscape rooms it has" do
      slugs = Array.new(60) { |i| described_class.for(board("board-#{i}")).slug }

      expect(slugs.uniq).to match_array(described_class.pool_for(landscape: true).map { |s| s[:slug] })
    end
  end

  # The paper pick needs its own salt for the same reason the palette does —
  # otherwise the room and the tablet move together and the rotation collapses.
  it "rotates independently of the tablet scene" do
    boards = Array.new(40) { |i| board("board-#{i}") }

    pairs = boards.map { |b| [described_class.for(b).slug, Boards::Printables::TabletScene.for(b).slug] }

    expect(pairs.uniq.size).to be > described_class.pool_for(landscape: true).size
  end
end
