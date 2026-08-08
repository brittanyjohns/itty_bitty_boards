require "rails_helper"

RSpec.describe Boards::AdminBuilder::WordListDrafter do
  def ai_tiles(*pairs)
    { "tiles" => pairs.map { |label, pos| { "label" => label, "part_of_speech" => pos } } }.to_json
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  let(:four_tiles) do
    ai_tiles(["I", "pronoun"], ["want", "verb"], ["more", "social"], ["swing", "noun"])
  end

  # Never let a spec reach the real API.
  before { stub_ai(four_tiles) }

  describe "#call" do
    it "returns labels with parts of speech" do
      result = described_class.new(topic: "the playground", tile_count: 4).call

      expect(result).to eq([
        { label: "I", part_of_speech: "pronoun" },
        { label: "want", part_of_speech: "verb" },
        { label: "more", part_of_speech: "social" },
        { label: "swing", part_of_speech: "noun" },
      ])
    end

    it "refuses to draft without a topic" do
      expect { described_class.new(topic: "  ", tile_count: 4).call }
        .to raise_error(described_class::GenerationError, /topic/)
    end

    it "trims a response longer than the grid" do
      stub_ai(ai_tiles(["I", "pronoun"], ["want", "verb"], ["more", "social"], ["swing", "noun"], ["slide", "noun"]))

      expect(described_class.new(topic: "the playground", tile_count: 4).call.size).to eq(4)
    end

    # Unlike Boards::AiPageGenerator this only fills a textarea, so a short
    # draft is survivable — the admin types the rest.
    it "returns a short draft rather than raising" do
      stub_ai(ai_tiles(["I", "pronoun"], ["want", "verb"]))

      expect(described_class.new(topic: "the playground", tile_count: 9).call.size).to eq(2)
    end

    it "tolerates 'word' as an alias for 'label'" do
      stub_ai({ "tiles" => [{ "word" => "swing", "part_of_speech" => "noun" }] }.to_json)

      expect(described_class.new(topic: "the playground", tile_count: 1).call)
        .to eq([{ label: "swing", part_of_speech: "noun" }])
    end
  end

  describe "cleanup of what the model returns" do
    # A draft that PlanValidator would reject on arrival is worse than a short
    # one, so exact and casing-only repeats are dropped here.
    it "drops a casing-only duplicate" do
      stub_ai(ai_tiles(["go", "verb"], ["Go", "verb"], ["stop", "important_function"]))

      result = described_class.new(topic: "the playground", tile_count: 3).call
      expect(result.map { |tile| tile[:label] }).to eq(%w[go stop])
    end

    it "falls back to default for a part of speech outside the Fitzgerald key" do
      stub_ai(ai_tiles(["swing", "gerund"]))

      expect(described_class.new(topic: "the playground", tile_count: 1).call)
        .to eq([{ label: "swing", part_of_speech: "default" }])
    end

    it "normalizes casing on the part of speech" do
      stub_ai(ai_tiles(["swing", "Noun"]))

      expect(described_class.new(topic: "the playground", tile_count: 1).call.first[:part_of_speech])
        .to eq("noun")
    end

    it "skips blank labels and non-hash entries" do
      stub_ai({ "tiles" => [{ "label" => "  " }, "nonsense", { "label" => "swing" }] }.to_json)

      expect(described_class.new(topic: "the playground", tile_count: 3).call)
        .to eq([{ label: "swing", part_of_speech: "default" }])
    end
  end

  describe "failures" do
    it "raises when OpenAI returns nothing" do
      stub_ai("")

      expect { described_class.new(topic: "the playground", tile_count: 4).call }
        .to raise_error(described_class::GenerationError, /no content/)
    end

    it "raises on unparseable JSON" do
      stub_ai("not json")

      expect { described_class.new(topic: "the playground", tile_count: 4).call }
        .to raise_error(described_class::GenerationError, /Failed to parse/)
    end

    it "raises when nothing in the response is usable" do
      stub_ai({ "tiles" => [] }.to_json)

      expect { described_class.new(topic: "the playground", tile_count: 4).call }
        .to raise_error(described_class::GenerationError, /no usable words/)
    end
  end

  describe "the prompt" do
    def prompt_for(**args)
      captured = nil
      allow(OpenAiClient).to receive(:new) do |opts|
        captured = opts[:messages].first[:content]
        instance_double(OpenAiClient, create_chat: { role: "assistant", content: four_tiles })
          .tap { |double| allow(double).to receive(:instance_variable_set) }
      end
      described_class.new(**args).call
      captured
    end

    it "asks for exactly the grid's worth of tiles" do
      expect(prompt_for(topic: "the playground", tile_count: 24)).to include("EXACTLY 24 tiles")
    end

    it "carries the core spine, in order, ahead of topic words" do
      prompt = prompt_for(topic: "the playground", tile_count: 24)

      expect(prompt).to include(described_class::CORE_SPINE.join(", "))
      expect(prompt).to include("before any topic words")
    end

    # A 2x2 board can't carry sixteen core words; asking for them would
    # guarantee the balance is wrong.
    it "asks only for as much of the spine as the grid can hold" do
      prompt = prompt_for(topic: "the playground", tile_count: 4)

      expect(prompt).to include("I, you, it, want")
      expect(prompt).not_to include("my turn")
    end

    it "carries the balance targets and the no-near-duplicates rule" do
      prompt = prompt_for(topic: "the playground", tile_count: 24)

      expect(prompt).to include("30-40% verbs and core function words")
      expect(prompt).to include("15-20% pronouns and determiners")
      expect(prompt).to include("15-20% describing words")
      expect(prompt).to include("25-35% topic nouns")
      expect(prompt).to include("No near-duplicates")
    end

    it "constrains the part of speech to the Fitzgerald key" do
      expect(prompt_for(topic: "the playground", tile_count: 4))
        .to include(ColorHelper::PARTS_OF_SPEECH.join(", "))
    end

    it "includes the audience only when one is given" do
      expect(prompt_for(topic: "the playground", tile_count: 4, audience: "a preschooler"))
        .to include("It is for: a preschooler")
      expect(prompt_for(topic: "the playground", tile_count: 4)).not_to include("It is for:")
    end
  end
end
