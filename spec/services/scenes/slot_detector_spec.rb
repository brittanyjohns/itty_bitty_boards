require "rails_helper"

RSpec.describe Scenes::SlotDetector do
  subject(:detector) { described_class.new(magenta_scene) }

  it "finds one slot per magenta surface and ignores the speck" do
    expect(detector.quads.size).to eq(2)
  end

  it "fits the clipped sheet with its own corners, clockwise from top-left, notch and all" do
    expect_quad_near(detector.quads.first, MagentaSceneHelpers::SHEET_QUAD, tolerance: 2)
  end

  it "fits the skewed, shaded screen within a few pixels" do
    expect_quad_near(detector.quads.last, MagentaSceneHelpers::SCREEN_QUAD, tolerance: 3)
  end

  it "returns quads the model's own shape checks accept" do
    detector.quads.each do |quad|
      slot = Boards::Printables::SceneSlot.new(quad: quad)
      expect(slot.clockwise_convex?).to be(true)
      expect(slot.degenerate?).to be(false)
    end
  end

  it "builds slot hashes in SceneTemplate's shape, guessing kind and orientation from the aspect" do
    sheet, screen = detector.call

    expect(sheet).to include("key" => "slot1", "kind" => "paper", "orientation" => "portrait",
                             "bleed_px" => described_class::DETECTED_BLEED_PX)
    expect(screen).to include("key" => "slot2", "kind" => "tablet", "orientation" => "landscape", "finish" => "glare")
    expect(sheet.keys).to match_array(SceneTemplate.normalize_slot({}).keys)
  end

  it "guesses a tag for the device-tag category" do
    slots = described_class.new(magenta_scene, category: "device_tag").call
    expect(slots.map { |slot| slot["kind"] }).to eq(%w[tag tag])
  end

  it "reports each slot's full-resolution bounding box" do
    detector.quads
    x0, y0, x1, y1 = detector.regions.first
    expect(x0).to be <= 20
    expect(y0).to be <= 20
    expect(x1).to be >= 79
    expect(y1).to be >= 109
  end

  it "finds nothing in a scene with no magenta" do
    expect(described_class.new(ChunkyPNG::Image.new(120, 90, ChunkyPNG::Color::WHITE)).call).to eq([])
  end

  it "orders a rotated square's corners from the top edge" do
    image = ChunkyPNG::Image.new(160, 160, ChunkyPNG::Color::WHITE)
    diamond = [[80, 20], [140, 80], [80, 140], [20, 80]]
    fill_quad(image, diamond) { MagentaSceneHelpers::MAGENTA }

    quad = described_class.new(image).quads.first
    expect(Boards::Printables::SceneSlot.new(quad: quad).clockwise_convex?).to be(true)
    expect(quad.map(&:last).min).to be <= 22
  end
end
