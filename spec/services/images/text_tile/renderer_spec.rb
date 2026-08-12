require "rails_helper"

# Chrome is stubbed throughout — what matters is the document we hand it.
RSpec.describe Images::TextTile::Renderer do
  def html_for(**params)
    described_class.new(Images::TextTile::Options.from_params({ text: "more" }.merge(params))).html
  end

  it "inlines exactly one family's faces and names it on the tile" do
    html = html_for(font: "fredoka")

    # Every @font-face is Fredoka's, plus the .tile rule that selects it.
    expect(html.scan("font-family: 'Fredoka'").size).to eq(html.scan("@font-face").size + 1)
    Images::TextTile::Fonts::FAMILIES.reject { |f| f.key == "fredoka" }.each do |other|
      expect(html).not_to include(other.css_family)
    end
  end

  it "escapes the user's text" do
    html = html_for(text: "<script>alert(1)</script>")

    expect(html).not_to include("<script>")
    expect(html).to include("&lt;script&gt;")
  end

  it "emits one div per wrapped line so the breaks match the preview's" do
    options = Images::TextTile::Options.from_params(text: "I want more please")
    html = described_class.new(options).html

    options.lines.each { |line| expect(html).to include("<div>#{line}</div>") }
  end

  describe "the CSS it builds" do
    it "uses only whitelisted color values" do
      html = html_for(text_color: "javascript:alert(1)", bg_color: "#abcdef")

      expect(html).not_to include("javascript:")
      expect(html).to include("color: #{Images::TextTile::Options::DEFAULT_TEXT_COLOR}")
      expect(html).to include("background: #abcdef")
    end

    it "leaves the body unpainted when transparent, so omitBackground can show through" do
      expect(html_for(bg_color: "transparent")).to include("background: none")
    end

    it "maps alignment onto both text-align and the flex axis" do
      html = html_for(align: "right")

      expect(html).to include("text-align: right")
      expect(html).to include("align-items: flex-end")
    end

    it "scales the reference font size onto its own canvas" do
      options = Images::TextTile::Options.from_params(text: "more")
      expected = (options.font_size_px * (described_class::SIZE / Images::TextTile::Options::REFERENCE_CANVAS)).round(2)

      expect(described_class.new(options).html).to include("font-size: #{expected}px")
    end
  end

  describe "#to_png" do
    it "renders a square canvas and passes transparency through to Chrome" do
      expect(HtmlToPng).to receive(:call).with(
        hash_including(width: described_class::SIZE, height: described_class::SIZE, transparent: true),
      ).and_return("png-bytes")

      options = Images::TextTile::Options.from_params(text: "more", bg_color: "transparent")
      expect(described_class.new(options).to_png).to eq("png-bytes")
    end
  end
end
