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

    # Five of every listing's thirteen slots were going to one-word tags that
    # compete with the whole marketplace. Blocked at the rule, not in the pools,
    # so a pool edit — or a one-word tag typed into the admin form — can't put
    # them back.
    it "rejects a single-word tag" do
      expect(described_class.normalize_tag("aac")).to be_nil
      expect(described_class.normalize_tag("Printable!")).to be_nil
    end

    it "keeps the two-word phrase version of a blocked word" do
      expect(described_class.normalize_tag("printable aac")).to eq("printable aac")
    end
  end

  describe ".assemble_tags" do
    it "caps at 13, dedupes, and fills the tail from top_up" do
      tags = described_class.assemble_tags(
        always_on: ["printable aac", "low tech aac"],
        product_type: ["printable aac"],
        audience: ["slp resources"],
        topic: ["farm animals"],
        top_up: (1..20).map { |i| "keyword #{i}" },
      )

      expect(tags.length).to eq(described_class::TAG_MAX)
      expect(tags.uniq).to eq(tags)
      # Topic ranks straight after always_on: it is the only pool describing
      # this particular product.
      expect(tags.first(4)).to eq(["printable aac", "low tech aac", "farm animals", "slp resources"])
    end

    it "ranks the topic above the product-type, audience and top-up pools" do
      tags = described_class.assemble_tags(
        always_on: ["printable aac"],
        product_type: ["communication board"],
        audience: ["classroom visuals"],
        topic: ["hospital stay", "doctor visit"],
        top_up: ["speech therapy"],
      )

      expect(tags).to eq(
        ["printable aac", "hospital stay", "doctor visit", "communication board",
         "classroom visuals", "speech therapy"],
      )
    end

    # An uncapped topic pool would take all 13 slots and evict the terms the
    # listings earning traffic today are found by. Note the arithmetic with a
    # maxed topic: 3 always-on + 6 topic + 1 product-type + 3 audience fills
    # the board exactly, so `top_up` is displaced — that's the priority order
    # working, and it only happens for a topic of 6+ distinct phrases.
    it "caps the topic so the product-type and audience pools keep their slots" do
      tags = described_class.assemble_tags(
        always_on: ["printable aac", "communication board", "low tech aac"],
        product_type: ["aac board"],
        audience: ["autism support", "slp resources", "classroom visuals"],
        topic: (1..12).map { |i| "topic phrase #{i}" },
        top_up: ["speech therapy"],
      )

      expect(tags.count { |t| t.start_with?("topic phrase") }).to eq(described_class::TOPIC_TAG_MAX)
      expect(tags).to include("communication board", "autism support")
      expect(tags.length).to eq(described_class::TAG_MAX)
    end

    # A topic of ordinary length — which is every real one — leaves the proven
    # top-up terms exactly where they were.
    it "leaves the top-up pool intact for a normal-length topic" do
      tags = described_class.assemble_tags(
        always_on: ["printable aac", "communication board", "low tech aac"],
        product_type: ["aac board"],
        audience: ["autism support", "slp resources", "classroom visuals"],
        topic: ["hospital stay", "doctor visit"],
        top_up: ["aac printable", "voice output aac", "speech therapy", "special education"],
      )

      expect(tags).to include("communication board", "speech therapy", "hospital stay")
      expect(tags.length).to eq(described_class::TAG_MAX)
    end

    it "honours an explicit topic_max" do
      tags = described_class.assemble_tags(
        always_on: [], topic: ["one thing", "two thing", "three thing"], top_up: ["speech therapy"],
        topic_max: 1,
      )

      expect(tags).to eq(["one thing", "speech therapy"])
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
      expect(described_class.topic_tags("core words / snack time")).to eq(["core words", "snack time"])
    end

    # A one-word segment yields nothing rather than a one-word tag — the
    # normalize_tag rule reaching the richest tag source there is.
    it "drops a segment that is a single word" do
      expect(described_class.topic_tags("core words / feelings")).to eq(["core words"])
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
