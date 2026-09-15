require "rails_helper"

RSpec.describe Scenes::MagentaMask do
  def score(r, g, b) = described_class.score_rgb(r, g, b)

  it "scores pure magenta fully" do
    expect(score(255, 0, 255)).to eq(1.0)
  end

  it "tolerates shading: a darker or slightly off magenta still counts" do
    expect(score(120, 0, 120)).to eq(1.0)
    expect(score(60, 0, 60)).to eq(1.0)
    expect(score(230, 30, 200)).to be >= 0.9
    expect(score(200, 20, 230)).to be >= 0.9
  end

  it "scores the scene's other colours as nothing" do
    [[255, 255, 255], [0, 0, 0], [128, 128, 128], [255, 0, 0], [0, 0, 255], [0, 255, 0],
     [216, 200, 168], [255, 200, 180], [10, 0, 12]].each do |rgb|
      expect(score(*rgb)).to eq(0.0), "expected #{rgb.inspect} to score 0"
    end
  end

  it "gives an antialiased edge a partial score" do
    half_white = score(255, 128, 255)
    expect(half_white).to be > 0.3
    expect(half_white).to be < 0.8
  end

  it "fades out beyond the hue window" do
    # ~285° (bluer) is inside; ~260° (violet) is out.
    expect(score(191, 0, 255)).to be > 0.9
    expect(score(85, 0, 255)).to eq(0.0)
  end

  it "never counts a transparent pixel" do
    expect(described_class.score(ChunkyPNG::Color.rgba(255, 0, 255, 0))).to eq(0.0)
  end

  it "reads pixels of an image" do
    mask = described_class.new(magenta_scene)
    expect(mask.magenta_at?(30, 60)).to be(true)
    expect(mask.magenta_at?(5, 5)).to be(false)
    expect(mask.magenta_at?(50, 22)).to be(false) # the clip
    expect(mask.magenta_at?(170, 60)).to be(true) # the shaded end of the screen
  end
end
