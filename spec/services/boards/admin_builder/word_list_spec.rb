require "rails_helper"

RSpec.describe Boards::AdminBuilder::WordList do
  describe ".parse" do
    it "reads a bare word as a default-coloured tile" do
      expect(described_class.parse("swing")).to eq([{ label: "swing", part_of_speech: "default" }])
    end

    it "reads a part of speech and tile text" do
      expect(described_class.parse("food | noun | Snacks"))
        .to eq([{ label: "food", part_of_speech: "noun", display_label: "Snacks" }])
    end

    it "finds the link field wherever it appears in the line" do
      expect(described_class.parse("Food | noun | >food"))
        .to eq([{ label: "Food", part_of_speech: "noun", links_to: "food" }])
    end

    it "downcases a link target and drops blank lines" do
      expect(described_class.parse("back | social | >__ROOT__\n\n  \n"))
        .to eq([{ label: "back", part_of_speech: "social", links_to: "__root__" }])
    end
  end

  describe ".render" do
    it "always emits the part of speech" do
      expect(described_class.render([{ label: "swing", part_of_speech: "noun" }])).to eq("swing | noun")
    end

    it "defaults a missing part of speech" do
      expect(described_class.render([{ label: "swing" }])).to eq("swing | default")
    end

    it "emits a link without forcing an empty tile-text field" do
      expect(described_class.render([{ label: "Food", part_of_speech: "noun", links_to: "food" }]))
        .to eq("Food | noun | >food")
    end

    it "emits tile text and a link together, in that order" do
      expect(described_class.render([{ label: "Food", part_of_speech: "noun", display_label: "Snacks", links_to: "food" }]))
        .to eq("Food | noun | Snacks | >food")
    end

    it "accepts string-keyed tiles as stored in the plan jsonb" do
      expect(described_class.render([{ "label" => "swing", "part_of_speech" => "noun" }])).to eq("swing | noun")
    end

    it "joins tiles with newlines" do
      tiles = [{ label: "I", part_of_speech: "pronoun" }, { label: "want", part_of_speech: "verb" }]
      expect(described_class.render(tiles)).to eq("I | pronoun\nwant | verb")
    end
  end

  # The round trip is what Task 9 (duplicate a build into the form) depends on.
  describe "round trip" do
    it "survives every combination of the optional fields" do
      tiles = [
        { label: "I", part_of_speech: "pronoun" },
        { label: "food", part_of_speech: "noun", display_label: "Snacks" },
        { label: "Food", part_of_speech: "noun", links_to: "food" },
        { label: "Home", part_of_speech: "social", display_label: "Back", links_to: "__root__" },
      ]

      expect(described_class.parse(described_class.render(tiles))).to eq(tiles)
    end
  end
end
