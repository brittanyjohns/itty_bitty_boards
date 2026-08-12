require "rails_helper"

# The security spine of the text-tile feature. Everything the client sends
# lands in an HTML document that Chrome then executes, so this object is the
# only thing between a user-supplied string and a render.
RSpec.describe Images::TextTile::Options do
  def build(**params)
    described_class.from_params({ text: "more" }.merge(params))
  end

  describe "font" do
    it "accepts a known key" do
      expect(build(font: "lexend").font).to eq("lexend")
    end

    it "rejects an unknown key loudly and still falls back to a real family" do
      options = build(font: "Comic Sans; }")

      expect(options).not_to be_valid
      expect(options.errors).to include("unknown_font")
      expect(options.font).to eq(Images::TextTile::Fonts::DEFAULT_KEY)
    end

    it "defaults a blank key without complaining" do
      options = build(font: nil)

      expect(options).to be_valid
      expect(options.font).to eq(Images::TextTile::Fonts::DEFAULT_KEY)
    end
  end

  describe "colors" do
    it "accepts 3- and 6-digit hex, normalized to lowercase" do
      expect(build(text_color: "#ABC").text_color).to eq("#abc")
      expect(build(text_color: "#A1B2C3").text_color).to eq("#a1b2c3")
    end

    it "accepts the transparent keyword for the background only" do
      expect(build(bg_color: "transparent")).to be_transparent
      expect(build(text_color: "transparent").text_color).to eq(described_class::DEFAULT_TEXT_COLOR)
    end

    it "discards anything that isn't a hex color rather than echoing it" do
      injection = "red; } body { background: url(https://evil.example/x) "
      options = build(text_color: injection, bg_color: injection)

      expect(options.text_color).to eq(described_class::DEFAULT_TEXT_COLOR)
      expect(options.bg_color).to eq(described_class::DEFAULT_BG_COLOR)
      expect(options.to_h.values.join).not_to include("evil.example")
    end
  end

  describe "enum tokens" do
    it "falls back to the default for values outside the whitelist" do
      options = build(size: "enormous", case: "sPoNgEbOb", align: "sideways")

      expect(options.size).to eq(described_class::DEFAULT_SIZE)
      expect(options.text_case).to eq(described_class::DEFAULT_CASE)
      expect(options.align).to eq(described_class::DEFAULT_ALIGN)
    end

    it "maps case tokens to server-owned CSS values" do
      expect(build(case: "upper").css_text_transform).to eq("uppercase")
      expect(build(case: "title").css_text_transform).to eq("capitalize")
      expect(build(case: "none").css_text_transform).to eq("none")
    end
  end

  describe "text" do
    it "strips and caps at MAX_TEXT_LENGTH" do
      options = build(text: "  #{"a" * 200}  ")

      expect(options.text.length).to eq(described_class::MAX_TEXT_LENGTH)
    end

    it "is not valid when blank — there is nothing to draw" do
      expect(build(text: "   ")).not_to be_valid
    end

    it "keeps markup as literal text rather than treating it as markup" do
      options = build(text: "</style><script>x</script>")

      # Escaping happens at render time; what matters here is that the raw
      # string survives intact for the renderer to escape, not that it's been
      # silently mangled into something else.
      expect(options.text).to include("<script>")
      expect(Images::TextTile::Renderer.new(options).html).not_to include("<script>")
    end
  end

  describe "booleans" do
    it "coerces the string forms the form sends" do
      expect(build(bold: "true").bold).to be(true)
      expect(build(bold: "false").bold).to be(false)
      expect(build(bold: nil).bold).to be(false)
    end

    it "defaults hide_label to true — the picture already says the word" do
      expect(build.hide_label).to be(true)
      expect(build(hide_label: "false").hide_label).to be(false)
    end
  end

  describe "#lines" do
    it "wraps on whitespace at MAX_CHARS_PER_LINE" do
      expect(build(text: "I want more please").lines).to eq(["I want", "more", "please"])
    end

    it "keeps an over-long single word on its own line" do
      expect(build(text: "supercalifragilistic").lines).to eq(["supercalifragilistic"])
    end

    it "ellipsizes past MAX_LINES" do
      lines = build(text: "one two three four five six seven").lines

      expect(lines.length).to eq(described_class::MAX_LINES)
      expect(lines.last).to end_with("...")
    end
  end

  describe "#font_size_px" do
    it "shrinks as the longest line grows" do
      expect(build(text: "a").font_size_px).to be > build(text: "elephants").font_size_px
    end

    it "caps by height so wrapped lines can't overflow the tile" do
      three = build(text: "I want more please")

      expect(three.lines.size).to eq(3)
      expect(three.font_size_px).to be < described_class::MAX_FONT_SIZE
    end

    # FIXTURE TABLE — the twin of the one in
    # itty-bitty-frontend/src/data/text_tile.test.ts. Both ports must agree
    # exactly or the editor's preview lies about what the render produces.
    {
      "more" => [["more"], 100.81],
      "I want more please" => [["I want", "more", "please"], 67.2],
      "+" => [["+"], described_class::MAX_FONT_SIZE],
      "supercalifragilistic" => [["supercalifragilistic"], described_class::MIN_FONT_SIZE],
      "all done" => [["all done"], 50.4],
    }.each do |text, (lines, size)|
      it "lays out #{text.inspect} the same way the TypeScript port does" do
        options = build(text: text)

        expect(options.lines).to eq(lines)
        expect(options.font_size_px).to be_within(0.1).of(size)
      end
    end

    it "lets a single glyph fill the tile — the point of a text picture" do
      expect(build(text: "+").font_size_px).to eq(described_class::MAX_FONT_SIZE)
    end

    it "scales by the size token as a multiplier, never an absolute" do
      small = build(text: "hi", size: "s").font_size_px
      large = build(text: "hi", size: "xl").font_size_px

      expect(large / small).to be_within(0.01).of(
        described_class::SIZES.fetch("xl") / described_class::SIZES.fetch("s"),
      )
    end

    it "never drops below MIN_FONT_SIZE at the smallest setting" do
      expect(build(text: "one two three four five six seven", size: "s").font_size_px)
        .to be >= described_class::MIN_FONT_SIZE * described_class::SIZES.fetch("s")
    end
  end

  describe "#display_text" do
    it "reflects the wrapped, ellipsized lines rather than the raw input" do
      expect(build(text: "one two three four five six seven").display_text).to end_with("...")
    end

    it "applies the case transform" do
      expect(build(text: "all done", case: "upper").display_text).to eq("ALL DONE")
      expect(build(text: "all done", case: "title").display_text).to eq("All Done")
    end
  end

  describe "#to_h" do
    it "round-trips through from_params unchanged" do
      options = build(text: "more", font: "fredoka", text_color: "#123456",
                      bg_color: "transparent", size: "l", bold: "true",
                      case: "upper", align: "left", hide_label: "false")

      expect(described_class.from_params(options.to_h.symbolize_keys).to_h).to eq(options.to_h)
    end

    it "emits only whitelisted keys, so a stored blob can't smuggle anything back" do
      expect(build.to_h.keys).to match_array(
        %w[text font text_color bg_color size bold italic case align hide_label],
      )
    end
  end

  describe "#render_digest" do
    it "ignores hide_label, which changes the tile but not the picture" do
      expect(build(hide_label: "true").render_digest).to eq(build(hide_label: "false").render_digest)
    end

    it "changes when anything that paints changes" do
      base = build.render_digest

      expect(build(text_color: "#ff0000").render_digest).not_to eq(base)
      expect(build(font: "fredoka").render_digest).not_to eq(base)
      expect(build(size: "xl").render_digest).not_to eq(base)
    end
  end
end
