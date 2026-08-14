require "rails_helper"

RSpec.describe Boards::AdminBuilder::TileArrangement do
  def tile(label, part_of_speech, links_to: nil)
    { label: label, part_of_speech: part_of_speech }.tap do |raw|
      raw[:links_to] = links_to if links_to
    end
  end

  def labels(tiles)
    described_class.arrange(tiles).map { |arranged| arranged[:label] }
  end

  describe "the bands themselves" do
    # A part of speech with no band would sort to the "default" fallback and be
    # coloured for one thing while sitting with another.
    it "covers every part of speech the Fitzgerald key defines" do
      expect(described_class::BAND_ORDER).to match_array(ColorHelper::PARTS_OF_SPEECH)
    end
  end

  describe ".arrange" do
    it "groups like words together, quick words first and nouns last" do
      tiles = [
        tile("swing", "noun"), tile("go", "verb"), tile("I", "pronoun"),
        tile("slide", "noun"), tile("push", "verb"), tile("you", "pronoun")
      ]

      expect(labels(tiles)).to eq(%w[I you go push swing slide])
    end

    it "keeps the drafted order inside a band" do
      tiles = [tile("I", "pronoun"), tile("you", "pronoun"), tile("it", "pronoun"), tile("my", "pronoun")]

      expect(labels(tiles)).to eq(%w[I you it my])
    end

    # The app puts navigation on the bottom row, and a back tile in the bottom
    # band keeps BackTileAlignment's mirror-swap a move between navigation cells.
    it "sorts anything that links somewhere after every word band" do
      tiles = [
        tile("Food", "noun", links_to: "food"),
        tile("back", "social", links_to: Boards::AdminBuilder::Plan::ROOT_KEY),
        tile("apple", "noun"),
        tile("I", "pronoun"),
      ]

      expect(labels(tiles)).to eq(["I", "apple", "Food", "back"])
    end

    it "sorts an unrecognized part of speech into the default band" do
      tiles = [tile("swing", "gerund"), tile("apple", "noun"), tile("I", "pronoun")]

      expect(labels(tiles)).to eq(%w[I apple swing])
    end

    it "sorts a tile with no part of speech at all into the default band" do
      tiles = [{ label: "swing" }, tile("I", "pronoun")]

      expect(labels(tiles)).to eq(%w[I swing])
    end

    it "returns an empty list unchanged" do
      expect(described_class.arrange([])).to eq([])
      expect(described_class.arrange(nil)).to eq([])
    end
  end

  # This is a permutation and nothing else: PlanValidator checks counts, and a
  # step that could change one would have to be re-checked at preview.
  describe "what it must never change" do
    let(:tiles) do
      [tile("swing", "noun"), tile("go", "verb"), tile("Food", "noun", links_to: "food"), tile("I", "pronoun")]
    end

    it "keeps every tile, with its label and its link" do
      arranged = described_class.arrange(tiles)

      expect(arranged.size).to eq(tiles.size)
      expect(arranged.map { |t| t[:label] }).to match_array(tiles.map { |t| t[:label] })
      expect(arranged.find { |t| t[:label] == "Food" }[:links_to]).to eq("food")
    end

    it "leaves the caller's tiles alone" do
      original = tiles.map(&:dup)
      described_class.arrange(tiles)

      expect(tiles).to eq(original)
    end

    it "is idempotent" do
      once = described_class.arrange(tiles)

      expect(described_class.arrange(once)).to eq(once)
    end
  end

  # A wrong part of speech is a wrong colour AND a wrong band, and these are the
  # words models most reliably get wrong. AacWordCategorizer::OVERRIDES is
  # already the app's authority for them, so the drafters and the rest of the
  # app agree on what colour "stop" is.
  describe "correcting the part of speech" do
    it "moves a protest word out of the verbs" do
      tiles = [tile("go", "verb"), tile("stop", "verb"), tile("I", "pronoun")]

      expect(labels(tiles)).to eq(%w[I stop go])
      expect(described_class.arrange(tiles).find { |t| t[:label] == "stop" }[:part_of_speech])
        .to eq("important_function")
    end

    it "reclassifies a request word as social" do
      expect(described_class.arrange([tile("more", "adjective")]).first[:part_of_speech]).to eq("social")
    end

    it "matches the override table case- and space-insensitively" do
      expect(described_class.arrange([tile("All  Done", "verb")]).first[:part_of_speech]).to eq("social")
    end

    it "leaves a word the table says nothing about alone" do
      expect(described_class.arrange([tile("swing", "noun")]).first[:part_of_speech]).to eq("noun")
    end

    # A door's label is a page NAME, not a word: "Play" opens a page, and
    # recolouring it because a word table knows the verb "play" would take it out
    # of the navigation band the whole set relies on.
    it "never recolours a tile that opens a page" do
      arranged = described_class.arrange([tile("Stop", "noun", links_to: "stop")])

      expect(arranged.first[:part_of_speech]).to eq("noun")
      expect(arranged.first[:links_to]).to eq("stop")
    end
  end
end
