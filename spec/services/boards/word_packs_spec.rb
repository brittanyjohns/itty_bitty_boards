require "rails_helper"

RSpec.describe Boards::WordPacks do
  describe "the catalog" do
    it "gives every pack a unique key, a name and at least one word" do
      keys = described_class::PACKS.map { |pack| pack[:key] }
      expect(keys).to eq(keys.uniq)

      described_class::PACKS.each do |pack|
        expect(pack[:name]).to be_present, "#{pack[:key]} has no name"
        expect(pack[:words]).to be_present, "#{pack[:key]} has no words"
      end
    end

    # ColorHelper::PARTS_OF_SPEECH is what ImageHelper#background_color_for
    # switches on, and that switch ends in `else "gray"` — an unrecognised value
    # doesn't fail, it silently miscolours every tile the pack adds. "phrase" is
    # the one legitimate non-Fitzgerald value (Image#ensure_defaults has a
    # branch for it).
    it "declares only parts of speech the colour resolver knows" do
      described_class::PACKS.each do |pack|
        expect(described_class::VALID_PARTS_OF_SPEECH).to include(pack[:part_of_speech]),
                                                          "#{pack[:key]} declares #{pack[:part_of_speech].inspect}"
      end
    end

    it "keeps each word in exactly one pack" do
      all_words = described_class::PACKS.flat_map { |pack| pack[:words] }.map { |w| described_class.normalize_key(w) }
      duplicates = all_words.tally.select { |_word, count| count > 1 }.keys
      expect(duplicates).to be_empty
    end

    it "never contradicts AacWordCategorizer::OVERRIDES" do
      described_class::PACKS.each do |pack|
        pack[:words].each do |word|
          key = described_class.normalize_key(word)
          override = AacWordCategorizer::OVERRIDES[key]
          next if override.nil?

          resolved = described_class.part_of_speech_map(pack[:key], [word])[key]
          expect(resolved).to eq(override),
                              "#{word.inspect} in #{pack[:key]} resolved #{resolved.inspect}, overrides say #{override.inspect}"
        end
      end
    end
  end

  describe ".part_of_speech_map" do
    it "uses the pack's own part of speech for a word the overrides don't cover" do
      expect(described_class.part_of_speech_map("pronouns", ["he"])).to eq("he" => "pronoun")
    end

    # Classification is by communicative FUNCTION, not grammar: a communicator
    # hitting "stop" is protesting, so it must stay important_function (red)
    # even though it sits in the action-words pack.
    it "defers to the overrides table where it has an opinion" do
      expect(described_class.part_of_speech_map("actions", ["stop"])).to eq("stop" => "important_function")
      expect(described_class.part_of_speech_map("social", ["no"])).to eq("no" => "important_function")
    end

    it "is empty for an unknown pack" do
      expect(described_class.part_of_speech_map("nope", ["he"])).to eq({})
    end
  end

  describe ".requested_words" do
    it "keeps only words the pack actually carries, in the pack's order" do
      expect(described_class.requested_words("pronouns", ["they", "ketchup", "he"])).to eq(%w[he they])
    end

    it "matches case-insensitively" do
      expect(described_class.requested_words("pronouns", ["HE"])).to eq(["he"])
    end

    it "is empty for an unknown pack" do
      expect(described_class.requested_words("nope", ["he"])).to eq([])
    end
  end

  # Sizes, condiments and ordering used to be scoped to `board_types: %w[menu]`
  # and reachable only from a Menu-parented board. There is no filter any more —
  # the catalog is the same everywhere — so this pins that no pack grows one
  # back by accident, which would silently take those words away again from the
  # ordinary boards people build a restaurant trip on.
  describe ".all" do
    it "offers every pack, with no per-board scoping" do
      expect(described_class.all.map { |p| p[:key] })
        .to eq(%w[pronouns actions social numbers sizes condiments ordering])
    end

    it "leaves no pack carrying a board-type scope" do
      expect(described_class::PACKS.select { |pack| pack.key?(:board_types) }).to be_empty
    end
  end
end
