require "rails_helper"

RSpec.describe Boards::AdminBuilder::PageNamesSuggester do
  def ai_pages(pages)
    { "pages" => pages }.to_json
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  let(:suggested) do
    ai_pages([
      { "key" => "snack_time", "name" => "Snack Time" },
      { "key" => "drinks", "name" => "Drinks" },
    ])
  end

  before { stub_ai(suggested) }

  def suggest(**overrides)
    described_class.new(**{ topic: "snack time at school", count: 2 }.merge(overrides)).call
  end

  describe "#call" do
    it "returns a key and a name per page" do
      expect(suggest).to eq([
        { key: "snack_time", name: "Snack Time" },
        { key: "drinks", name: "Drinks" },
      ])
    end

    it "refuses to suggest without a name or a topic" do
      expect { suggest(topic: "  ") }.to raise_error(described_class::GenerationError, /topic/)
    end

    it "works from the board name alone" do
      expect(suggest(topic: "", name: "Snack Time")).not_to be_empty
    end

    it "trims to the requested count" do
      expect(suggest(count: 1).map { |page| page[:key] }).to eq(["snack_time"])
    end

    it "caps the count at what the set drafter will accept" do
      expect(described_class.new(topic: "a", count: 99).send(:count))
        .to eq(Boards::AdminBuilder::SetDrafter::MAX_PAGES)
    end
  end

  # What the admin typed is authoritative — it comes back first, unchanged,
  # and a suggestion that repeats it doesn't get a second block.
  describe "pages the admin already named" do
    it "keeps them first and unchanged" do
      pages = suggest(count: 2, existing: [{ key: "treats", name: "Treats" }])

      expect(pages).to eq([
        { key: "treats", name: "Treats" },
        { key: "snack_time", name: "Snack Time" },
      ])
    end

    it "doesn't repeat one the model named again" do
      stub_ai(ai_pages([{ "key" => "treats", "name" => "Treats and Snacks" },
                        { "key" => "drinks", "name" => "Drinks" }]))

      pages = suggest(count: 2, existing: [{ key: "treats", name: "Treats" }])

      expect(pages).to eq([
        { key: "treats", name: "Treats" },
        { key: "drinks", name: "Drinks" },
      ])
    end

    it "derives the key from a page named without one" do
      expect(suggest(count: 1, existing: [{ key: "", name: "Quiet Time" }]))
        .to eq([{ key: "quiet_time", name: "Quiet Time" }])
    end

    # Nothing left to ask about, so nothing is asked.
    it "skips the AI call when they already fill the count" do
      expect(OpenAiClient).not_to receive(:new)

      expect(suggest(count: 1, existing: [{ key: "treats", name: "Treats" }]))
        .to eq([{ key: "treats", name: "Treats" }])
    end
  end

  describe "cleanup of what the model returns" do
    it "normalizes a key to lowercase letters, numbers and underscores" do
      stub_ai(ai_pages([{ "key" => "Snack Time!", "name" => "Snack Time" }]))

      expect(suggest(count: 1).first[:key]).to eq("snack_time")
    end

    it "derives a key from the name when the model omitted one" do
      stub_ai(ai_pages([{ "name" => "Snack Time" }]))

      expect(suggest(count: 1).first[:key]).to eq("snack_time")
    end

    it "falls back to the key when the model omitted the name" do
      stub_ai(ai_pages([{ "key" => "snack_time" }]))

      expect(suggest(count: 1).first[:name]).to eq("Snack Time")
    end

    it "drops a page with nothing usable in it" do
      stub_ai(ai_pages([{ "key" => "  ", "name" => "  " }, { "key" => "drinks", "name" => "Drinks" }]))

      expect(suggest(count: 2).map { |page| page[:key] }).to eq(["drinks"])
    end

    it "drops a key that repeats an earlier one" do
      stub_ai(ai_pages([{ "key" => "drinks", "name" => "Drinks" },
                        { "key" => "drinks", "name" => "More Drinks" }]))

      expect(suggest(count: 2).map { |page| page[:name] }).to eq(["Drinks"])
    end
  end

  describe "failures" do
    it "raises when OpenAI returns nothing" do
      stub_ai("")
      expect { suggest }.to raise_error(described_class::GenerationError, /no content/)
    end

    it "raises on unparseable JSON" do
      stub_ai("not json")
      expect { suggest }.to raise_error(described_class::GenerationError, /Failed to parse/)
    end

    it "raises when nothing usable came back" do
      stub_ai(ai_pages([]))
      expect { suggest }.to raise_error(described_class::GenerationError, /no usable page names/)
    end
  end

  describe "the prompt" do
    def prompt_for(**args)
      captured = nil
      allow(OpenAiClient).to receive(:new) do |opts|
        captured = opts[:messages].first[:content]
        instance_double(OpenAiClient, create_chat: { role: "assistant", content: suggested })
          .tap { |double| allow(double).to receive(:instance_variable_set) }
      end
      described_class.new(**{ topic: "snack time at school", count: 2 }.merge(args)).call
      captured
    end

    it "asks for titles only" do
      expect(prompt_for).to include("Do not write any words or tiles")
    end

    it "asks for the requested number of pages" do
      expect(prompt_for).to include("Name the 2 pages")
    end

    it "includes the audience only when one is given" do
      expect(prompt_for(audience: "a preschooler")).to include("It is for: a preschooler")
      expect(prompt_for).not_to include("It is for:")
    end

    it "repeats back the pages the admin already chose" do
      prompt = prompt_for(count: 2, existing: [{ key: "treats", name: "Treats" }])

      expect(prompt).to include("already chosen: \"Treats\"")
    end
  end
end
