require "rails_helper"

RSpec.describe Boards::Printables::SceneSlot do
  # The quad maths as MockupScene computed it before it was extracted, written
  # out independently so the extraction can't quietly change a number.
  def legacy_target(quad)
    tl, tr, br, bl = quad
    dist = ->(a, b) { Math.hypot(b[0] - a[0], b[1] - a[1]) }

    [((dist.call(tl, tr) + dist.call(bl, br)) / 2.0).round, ((dist.call(tl, bl) + dist.call(tr, br)) / 2.0).round]
  end

  describe "parity with MockupScene for every vendored scene" do
    (Boards::Printables::TabletScene::SCENES + Boards::Printables::PaperScene::SCENES).each do |values|
      context values[:slug] do
        let(:scene) { Boards::Printables::MockupScene.new(values) }
        let(:slot) { described_class.new(quad: values[:quad]) }

        it "sizes the letterbox rectangle exactly as before" do
          expect([slot.target_width, slot.target_height]).to eq(legacy_target(values[:quad]))
          expect([scene.target_width, scene.target_height]).to eq(legacy_target(values[:quad]))
        end

        it "produces the same matrix3d" do
          width, height = legacy_target(values[:quad])

          expect(slot.matrix3d).to eq(Boards::Printables::Homography.matrix3d(width, height, values[:quad]))
          expect(scene.matrix3d).to eq(slot.matrix3d)
        end

        it "is clockwise, convex and solvable — what SceneTemplate will demand of it" do
          expect(slot).to be_clockwise_convex
          expect(slot).not_to be_degenerate
        end
      end
    end
  end

  describe "#with_bleed" do
    let(:quad) { [[100, 100], [300, 100], [300, 250], [100, 250]] }

    it "returns itself when there is no bleed" do
      slot = described_class.new(quad: quad)

      expect(slot.with_bleed).to equal(slot)
    end

    it "pushes every corner outward, away from the centroid" do
      grown = described_class.new(quad: quad, bleed_px: 5).with_bleed

      tl, tr, br, bl = grown.quad
      expect(tl[0]).to be < 100
      expect(tl[1]).to be < 100
      expect(tr[0]).to be > 300
      expect(br[1]).to be > 250
      expect(bl[0]).to be < 100
      expect(grown.bleed_px).to eq(0)
    end

    it "keeps the slot's identity and finish" do
      grown = described_class.new(quad: quad, bleed_px: 2, key: "sheet", finish: "shadow").with_bleed

      expect([grown.key, grown.finish]).to eq(%w[sheet shadow])
    end
  end

  describe "shape checks" do
    it "rejects counter-clockwise corners" do
      expect(described_class.new(quad: [[0, 0], [0, 10], [10, 10], [10, 0]])).not_to be_clockwise_convex
    end

    it "rejects a bow-tie" do
      expect(described_class.new(quad: [[0, 0], [10, 0], [0, 10], [10, 10]])).not_to be_clockwise_convex
    end

    it "treats collinear corners as degenerate" do
      expect(described_class.new(quad: [[0, 0], [5, 0], [10, 0], [15, 0]])).to be_degenerate
    end
  end

  it "reads a stored slot hash" do
    slot = described_class.from_hash("key" => "sheet", "kind" => "paper", "quad" => [[0, 0], [20, 0], [20, 10], [0, 10]],
                                     "accepts" => ["upload"], "finish" => "none", "bleed_px" => 2)

    expect([slot.key, slot.kind, slot.accepts, slot.finish, slot.bleed_px]).to eq(["sheet", "paper", ["upload"], "none", 2.0])
    expect(slot).to be_quad_landscape
  end
end
