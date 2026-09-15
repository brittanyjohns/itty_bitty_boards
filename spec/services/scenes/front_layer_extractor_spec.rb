require "rails_helper"

RSpec.describe Scenes::FrontLayerExtractor do
  let(:scene) do
    magenta_scene.tap do |image|
      # A 50/50 blend of magenta and white on the sheet: an antialiased pixel.
      image.set_pixel(21, 60, ChunkyPNG::Color.rgb(255, 128, 255))
    end
  end
  let(:sheet) { SceneTemplate.normalize_slot("key" => "sheet", "quad" => MagentaSceneHelpers::SHEET_QUAD, "bleed_px" => 0) }
  let(:layer) { described_class.new(scene, [sheet]).call }

  def alpha(x, y) = ChunkyPNG::Color.a(layer.get_pixel(x, y))

  it "is the same size as the scene" do
    expect([layer.width, layer.height]).to eq([scene.width, scene.height])
  end

  it "copies the occluder opaque" do
    expect(alpha(50, 22)).to eq(255)
    expect(layer.get_pixel(50, 22)).to eq(MagentaSceneHelpers::CLIP_GREY)
  end

  it "is transparent where the placeholder is magenta, so the art shows" do
    expect(alpha(30, 60)).to eq(0)
    expect(alpha(79, 109)).to eq(0)
  end

  it "is transparent outside every slot, even over the clip's part that sticks out" do
    expect(alpha(5, 5)).to eq(0)
    expect(alpha(50, 15)).to eq(0)
    expect(alpha(150, 60)).to eq(0) # the other surface, which this layer has no slot for
  end

  it "gives a blended edge partial alpha with the magenta spill removed" do
    pixel = layer.get_pixel(21, 60)
    r = ChunkyPNG::Color.r(pixel)
    g = ChunkyPNG::Color.g(pixel)
    b = ChunkyPNG::Color.b(pixel)

    expect(alpha(21, 60)).to be_between(1, 254)
    expect([r, b].min).to be <= g
    expect((r - g).abs).to be <= 2
  end

  it "keeps a despilled pixel's brightness" do
    r, g, b = described_class.despill(255, 128, 255)
    expect([r, g, b].uniq.size).to eq(1)
    expect(described_class.luminance(r, g, b)).to be_within(1.5).of(described_class.luminance(255, 128, 255))
    expect(described_class.despill(90, 90, 96)).to eq([90, 90, 96])
  end

  it "covers the footprint the art bleeds into" do
    bled = SceneTemplate.normalize_slot("key" => "sheet", "quad" => MagentaSceneHelpers::SHEET_QUAD, "bleed_px" => 8)
    bled_layer = described_class.new(scene, [bled]).call

    # Scene background outside the magenta but inside the bleed: drawn over the art.
    expect(ChunkyPNG::Color.a(bled_layer.get_pixel(15, 60))).to eq(255)
    expect(ChunkyPNG::Color.a(layer.get_pixel(15, 60))).to eq(0)
  end

  it "overlaps the art's edge by a couple of pixels so its antialiased rim never shows" do
    # One pixel left of the sheet: outside a bleed-0 quad, inside the overlap.
    expect(alpha(19, 60)).to eq(255)
    expect(layer.get_pixel(19, 60)).to eq(MagentaSceneHelpers::SCENE_BG)
  end
end
