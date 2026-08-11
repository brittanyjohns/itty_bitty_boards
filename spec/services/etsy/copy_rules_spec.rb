require "rails_helper"

RSpec.describe Etsy::CopyRules do
  describe ".enforce_title_rules" do
    it "keeps the first ampersand and turns later ones into 'and'" do
      # Etsy 400s a title with more than one "&".
      expect(described_class.enforce_title_rules("Farm & Zoo for Speech & Autism"))
        .to eq("Farm & Zoo for Speech and Autism")
    end

    it "collapses runs of whitespace" do
      expect(described_class.enforce_title_rules("Core   Words  Board ")).to eq("Core Words Board")
    end
  end

  describe ".ensure_digital_download_suffix" do
    it "appends the suffix" do
      expect(described_class.ensure_digital_download_suffix("Core Words"))
        .to eq("Core Words (Digital Download)")
    end

    it "leaves an existing suffix alone" do
      expect(described_class.ensure_digital_download_suffix("Core Words (Digital Download)"))
        .to eq("Core Words (Digital Download)")
    end

    it "keeps the whole title within Etsy's cap" do
      result = described_class.ensure_digital_download_suffix("a" * 200)
      expect(result.length).to be <= described_class::TITLE_MAX
      expect(result).to end_with("(Digital Download)")
    end
  end

  describe ".normalize_tag" do
    it "downcases and strips characters Etsy rejects" do
      expect(described_class.normalize_tag("AAC Board!")).to eq("aac board")
    end

    it "rejects a tag over 20 characters rather than truncating it" do
      expect(described_class.normalize_tag("talking communication board")).to be_nil
    end

    it "rejects a phrase made only of small words" do
      expect(described_class.normalize_tag("for the")).to be_nil
    end
  end

  describe ".assemble_tags" do
    it "caps at 13, dedupes, and fills the tail from top_up" do
      tags = described_class.assemble_tags(
        always_on: ["aac", "printable"],
        product_type: ["aac"],
        audience: ["slp"],
        topic: ["farm animals"],
        top_up: (1..20).map { |i| "keyword #{i}" },
      )

      expect(tags.length).to eq(described_class::TAG_MAX)
      expect(tags.uniq).to eq(tags)
      expect(tags.first(4)).to eq(["aac", "printable", "slp", "farm animals"])
    end
  end

  describe ".topic_tags" do
    it "falls back to a segment's TRAILING phrase when the whole is too long" do
      # The head noun carries the search intent: "animal vocabulary", not
      # "farm and".
      expect(described_class.topic_tags("farm and zoo animal vocabulary"))
        .to include("animal vocabulary")
    end

    it "splits on commas and slashes" do
      expect(described_class.topic_tags("core words / feelings")).to eq(["core words", "feelings"])
    end
  end

  describe ".pick_fitting_title" do
    it "returns the first candidate that fits once the suffix is accounted for" do
      long = "x" * 130
      expect(described_class.pick_fitting_title([long, "Core Words"])).to eq("Core Words")
    end

    it "returns the shortest when everything overflows, rather than an early truncation" do
      expect(described_class.pick_fitting_title(["y" * 200, "z" * 150])).to eq("z" * 150)
    end

    it "skips candidates carrying a stringified nil from an absent phrase" do
      expect(described_class.pick_fitting_title(["Core Words, , Set"])).to eq("Core Words, , Set")
      expect(described_class.pick_fitting_title(["Core Words, nil Set", "Core Words"]))
        .to eq("Core Words")
    end
  end

  describe ".distinct_topic_phrase" do
    it "picks the segment adding the most words the title doesn't have" do
      phrase = described_class.distinct_topic_phrase(
        title: "Core 60", topic: "core vocabulary / core words for snack time",
        product_human: "vocabulary board",
      )
      expect(phrase).to eq("Core Words for Snack Time")
    end

    it "returns nil when the topic adds nothing new" do
      expect(described_class.distinct_topic_phrase(
               title: "Core Words", topic: "core words", product_human: "vocabulary board",
             )).to be_nil
    end
  end
end
