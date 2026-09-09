require "rails_helper"

# CareText is the single cleaning rule for every free-text care value, and the
# thing these specs pin is the split between the two kinds of field: a
# `short_text` field is a textarea a parent types a LIST into, so its line
# breaks are content, while every other surface here (section title, detail row,
# custom chip) is a one-line control where a pasted break is noise.
RSpec.describe CareText do
  describe ".clean" do
    it "strips markup and unescapes entities" do
      expect(described_class.clean("<b>hugs</b> &amp; quiet", 300))
        .to eq("hugs & quiet")
    end

    it "squishes newlines on a single-line field" do
      expect(described_class.clean("Cups\nand lids", 60)).to eq("Cups and lids")
    end

    context "multiline: true" do
      it "keeps the line breaks a parent typed" do
        text = "He bolts when scared.\nHe rides Bus 14.\nFront-right seat."

        expect(described_class.clean(text, 300, multiline: true)).to eq(text)
      end

      it "collapses horizontal whitespace and whitespace around a break" do
        expect(described_class.clean("Bus  14   \n   Front  seat", 300, multiline: true))
          .to eq("Bus 14\nFront seat")
      end

      it "caps a runaway blank-line run at one blank line" do
        expect(described_class.clean("one\n\n\n\n\ntwo", 300, multiline: true))
          .to eq("one\n\ntwo")
      end

      it "strips leading and trailing whitespace, newlines included" do
        expect(described_class.clean("\n\n  Bus 14  \n\n", 300, multiline: true))
          .to eq("Bus 14")
      end

      it "is idempotent" do
        text = "He bolts when scared.\n\nHe rides Bus 14.\nFront-right seat."
        once = described_class.clean(text, 300, multiline: true)

        expect(described_class.clean(once, 300, multiline: true)).to eq(once)
      end

      it "is idempotent when the value is truncated at the cap" do
        once = described_class.clean("#{'a' * 58}\nbb", 60, multiline: true)

        expect(described_class.clean(once, 60, multiline: true)).to eq(once)
      end

      it "still strips markup and unescapes" do
        expect(described_class.clean("<b>hugs</b> &amp; quiet\n&lt;script&gt;x", 300,
                                     multiline: true))
          .to eq("hugs & quiet\nx")
      end

      it "returns nil for whitespace-only text" do
        expect(described_class.clean("\n\n   \n", 300, multiline: true)).to be_nil
      end
    end
  end

  describe ".multiline?" do
    it "is true only for short_text" do
      expect(described_class.multiline?(:short_text)).to be(true)
      expect(described_class.multiline?("short_text")).to be(true)
      expect(described_class.multiline?(:multi_select)).to be(false)
      expect(described_class.multiline?(:single_select)).to be(false)
    end
  end
end
