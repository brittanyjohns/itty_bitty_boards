require "rails_helper"

RSpec.describe Images::TextTile::Fonts do
  # CROSS-REPO CONTRACT. The frontend preview picks its families from
  # TEXT_TILE_FONTS in itty-bitty-frontend/src/data/text_tile.ts, and loads
  # them from Google Fonts by the same css_family name. A key that exists on
  # one side only means the preview silently renders in a different typeface
  # than the tile it is previewing. text_tile.test.ts asserts the same list.
  EXPECTED_KEYS = %w[atkinson andika lexend nunito fredoka].freeze

  it "declares exactly the families the frontend knows about" do
    expect(described_class::KEYS).to eq(EXPECTED_KEYS)
  end

  it "defaults to a family it actually declares" do
    expect(described_class::KEYS).to include(described_class::DEFAULT_KEY)
  end

  describe "the vendored files" do
    it "are all present and non-empty" do
      described_class::KEYS.each do |key|
        described_class.files_for(key).each do |path|
          expect(path).to exist, "missing woff2 for #{key}: #{path}"
          expect(path.size).to be > 0, "empty woff2 for #{key}: #{path}"
        end
      end
    end

    # The OFL requires the license to travel with the font.
    it "ship an OFL.txt beside each family" do
      described_class::KEYS.each do |key|
        expect(described_class.license_path(key)).to exist, "missing OFL.txt for #{key}"
      end
    end

    it "cover both latin and latin-ext so an accented label doesn't fall back" do
      described_class::KEYS.each do |key|
        names = described_class.files_for(key).map { |p| p.basename.to_s }
        expect(names).to include(a_string_including("latin-ext")), "#{key} has no latin-ext"
        expect(names).to include(a_string_matching(/latin(?!-ext)/)), "#{key} has no latin"
      end
    end
  end

  describe ".face_css" do
    it "emits only the requested family" do
      css = described_class.face_css("fredoka")

      expect(css).to include("font-family: 'Fredoka'")
      expect(css).not_to include("Atkinson Hyperlegible")
      expect(css).not_to include("Lexend")
    end

    it "inlines the bytes rather than linking out — a render must not touch the network" do
      css = described_class.face_css("nunito")

      expect(css).to include("url(data:font/woff2;base64,")
      expect(css).not_to include("http")
    end

    it "declares normal style only, so preview and render synthesize the same oblique" do
      described_class::KEYS.each do |key|
        expect(described_class.face_css(key)).not_to include("font-style: italic")
      end
    end

    it "falls back to the default family for an unknown key rather than raising" do
      expect { described_class.face_css("nope") }.not_to raise_error
      expect(described_class.face_css("nope")).to eq(described_class.face_css(described_class::DEFAULT_KEY))
    end
  end
end
