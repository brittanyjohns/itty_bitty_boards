require "rails_helper"

# Trim points for a tile video. Whole seconds only — the YouTube embed API
# takes no fractional values. Returns {} for "no range supplied" and nil for
# "supplied but unusable"; the caller must be able to tell those apart.
RSpec.describe BoardImage, ".parse_video_range" do
  it "returns an empty hash when neither bound is supplied" do
    expect(described_class.parse_video_range(nil, nil)).to eq({})
    expect(described_class.parse_video_range("", "")).to eq({})
  end

  it "parses each bound independently" do
    expect(described_class.parse_video_range("45", nil)).to eq({ "start_seconds" => 45 })
    expect(described_class.parse_video_range(nil, "72")).to eq({ "end_seconds" => 72 })
    expect(described_class.parse_video_range("45", "72"))
      .to eq({ "start_seconds" => 45, "end_seconds" => 72 })
  end

  it "accepts integers as well as numeric strings" do
    expect(described_class.parse_video_range(45, 72))
      .to eq({ "start_seconds" => 45, "end_seconds" => 72 })
  end

  it "accepts zero as a start" do
    expect(described_class.parse_video_range("0", "10"))
      .to eq({ "start_seconds" => 0, "end_seconds" => 10 })
  end

  it "rejects negative values" do
    expect(described_class.parse_video_range("-1", nil)).to be_nil
    expect(described_class.parse_video_range(nil, "-5")).to be_nil
  end

  it "rejects fractional and non-numeric values" do
    expect(described_class.parse_video_range("3.5", nil)).to be_nil
    expect(described_class.parse_video_range("abc", nil)).to be_nil
    expect(described_class.parse_video_range(nil, "1:23")).to be_nil
  end

  it "rejects an end that is not strictly after the start" do
    expect(described_class.parse_video_range("72", "45")).to be_nil
    expect(described_class.parse_video_range("45", "45")).to be_nil
  end
end
