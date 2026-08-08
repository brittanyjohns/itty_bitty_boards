require "rails_helper"

RSpec.describe Boards::AdminBuilder::SetDrafter do
  def tile(label, pos, links_to = nil)
    { "label" => label, "part_of_speech" => pos }.tap { |t| t["links_to"] = links_to if links_to }
  end

  def ai_set(root:, pages: [])
    { "root" => root, "pages" => pages }.to_json
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  let(:valid_set) do
    ai_set(
      root: [tile("I", "pronoun"), tile("want", "verb"), tile("more", "social"), tile("Food", "noun", "food")],
      pages: [
        {
          "key" => "food",
          "name" => "Food",
          "tiles" => [tile("apple", "noun"), tile("hungry", "adjective"),
                      tile("eat", "verb"), tile("back", "social", "__root__")],
        },
      ],
    )
  end

  before { stub_ai(valid_set) }

  def draft(**overrides)
    described_class.new(**{ topic: "the playground", columns: 2, tile_count: 4, page_count: 1 }.merge(overrides)).call
  end

  describe "#call" do
    it "returns the root tiles and one child page" do
      result = draft

      expect(result[:root_tiles]).to eq([
        { label: "I", part_of_speech: "pronoun" },
        { label: "want", part_of_speech: "verb" },
        { label: "more", part_of_speech: "social" },
        { label: "Food", part_of_speech: "noun", links_to: "food" },
      ])
      expect(result[:children].size).to eq(1)
      expect(result[:children].first[:key]).to eq("food")
      expect(result[:children].first[:name]).to eq("Food")
      expect(result[:children].first[:tiles].last)
        .to eq({ label: "back", part_of_speech: "social", links_to: "__root__" })
    end

    it "refuses to draft without a topic" do
      expect { draft(topic: "  ") }.to raise_error(described_class::GenerationError, /topic/)
    end

    # A page count of zero is a single-board draft. Asking a second prompt for
    # what WordListDrafter already does would be paying twice for one answer.
    it "delegates a zero-page draft to WordListDrafter" do
      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(topic: "the playground", tile_count: 4, audience: nil)
        .and_return(instance_double(Boards::AdminBuilder::WordListDrafter,
                                    call: [{ label: "swing", part_of_speech: "noun" }]))

      expect(draft(page_count: 0)).to eq(
        { root_tiles: [{ label: "swing", part_of_speech: "noun" }], children: [] },
      )
    end

    it "re-raises a delegated drafter failure as its own error" do
      allow(Boards::AdminBuilder::WordListDrafter).to receive(:new).and_raise(
        Boards::AdminBuilder::WordListDrafter::GenerationError, "no usable words",
      )

      expect { draft(page_count: 0) }.to raise_error(described_class::GenerationError, /no usable words/)
    end
  end

  describe "cleanup of what the model returns" do
    it "drops a link pointing at a page that isn't in the set" do
      stub_ai(ai_set(root: [tile("Toys", "noun", "toys")], pages: []))

      expect(draft(columns: 1, tile_count: 1, page_count: 1)[:root_tiles])
        .to eq([{ label: "Toys", part_of_speech: "noun" }])
    end

    it "keeps a child's link back to the root" do
      stub_ai(ai_set(root: [tile("Food", "noun", "food")],
                     pages: [{ "key" => "food", "name" => "Food", "tiles" => [tile("back", "social", "__root__")] }]))

      expect(draft(columns: 1, tile_count: 1)[:children].first[:tiles].first[:links_to]).to eq("__root__")
    end

    # The root linking to itself would build a tile that opens the board it is
    # already on.
    it "drops a root tile linking to the root" do
      stub_ai(ai_set(root: [tile("Home", "social", "__root__")], pages: []))

      expect(draft(columns: 1, tile_count: 1)[:root_tiles]).to eq([{ label: "Home", part_of_speech: "social" }])
    end

    it "normalizes a page key to lowercase letters, numbers and underscores" do
      stub_ai(ai_set(root: [tile("Food", "noun", "food")],
                     pages: [{ "key" => "Food Time!", "name" => "Food", "tiles" => [tile("apple", "noun")] }]))

      expect(draft(columns: 1, tile_count: 1)[:children].first[:key]).to eq("food_time")
    end

    it "drops a page with no usable key" do
      stub_ai(ai_set(root: [tile("I", "pronoun")],
                     pages: [{ "key" => "  ", "name" => "Food", "tiles" => [tile("apple", "noun")] }]))

      expect(draft(columns: 1, tile_count: 1)[:children]).to be_empty
    end

    it "drops a page whose key repeats an earlier one" do
      stub_ai(ai_set(root: [tile("I", "pronoun")],
                     pages: [
                       { "key" => "food", "name" => "Food", "tiles" => [tile("apple", "noun")] },
                       { "key" => "food", "name" => "More Food", "tiles" => [tile("pear", "noun")] },
                     ]))

      children = draft(columns: 1, tile_count: 1, page_count: 2)[:children]
      expect(children.map { |child| child[:name] }).to eq(["Food"])
    end

    it "drops a casing-only duplicate within a page" do
      stub_ai(ai_set(root: [tile("go", "verb"), tile("Go", "verb"), tile("stop", "important_function")], pages: []))

      expect(draft(columns: 3, tile_count: 3, page_count: 1)[:root_tiles].map { |t| t[:label] })
        .to eq(%w[go stop])
    end

    it "falls back to default for a part of speech outside the Fitzgerald key" do
      stub_ai(ai_set(root: [tile("swing", "gerund")], pages: []))

      expect(draft(columns: 1, tile_count: 1)[:root_tiles].first[:part_of_speech]).to eq("default")
    end

    it "trims a page longer than the requested tile count" do
      stub_ai(ai_set(root: [tile("I", "pronoun"), tile("want", "verb"), tile("more", "social")], pages: []))

      expect(draft(columns: 1, tile_count: 2)[:root_tiles].size).to eq(2)
    end

    # Same tolerance as WordListDrafter: this only fills a form, and the
    # counter shows the gap.
    it "returns a short draft rather than raising" do
      stub_ai(ai_set(root: [tile("I", "pronoun")], pages: []))

      expect(draft(columns: 3, tile_count: 9)[:root_tiles].size).to eq(1)
    end
  end

  describe "failures" do
    it "raises when OpenAI returns nothing" do
      stub_ai("")
      expect { draft }.to raise_error(described_class::GenerationError, /no content/)
    end

    it "raises on unparseable JSON" do
      stub_ai("not json")
      expect { draft }.to raise_error(described_class::GenerationError, /Failed to parse/)
    end

    it "raises when the root came back empty" do
      stub_ai(ai_set(root: [], pages: []))
      expect { draft }.to raise_error(described_class::GenerationError, /no usable words/)
    end
  end

  describe "the prompt" do
    def prompt_for(**args)
      captured = nil
      allow(OpenAiClient).to receive(:new) do |opts|
        captured = opts[:messages].first[:content]
        instance_double(OpenAiClient, create_chat: { role: "assistant", content: valid_set })
          .tap { |double| allow(double).to receive(:instance_variable_set) }
      end
      described_class.new(**{ topic: "the playground", columns: 6, tile_count: 24, page_count: 2 }.merge(args)).call
      captured
    end

    it "asks for exactly the requested tile count on every page" do
      expect(prompt_for).to include("EXACTLY 24 tiles")
    end

    it "asks for the requested number of pages" do
      expect(prompt_for).to include("exactly 2 pages")
    end

    it "requires a folder tile on the root for every page" do
      expect(prompt_for).to include("one tile on the main board that opens it")
    end

    it "requires a way back from every page" do
      expect(prompt_for).to include(Boards::AdminBuilder::Plan::ROOT_KEY)
    end

    it "constrains the part of speech to the Fitzgerald key" do
      expect(prompt_for).to include(ColorHelper::PARTS_OF_SPEECH.join(", "))
    end

    it "includes the audience only when one is given" do
      expect(prompt_for(audience: "a preschooler")).to include("It is for: a preschooler")
      expect(prompt_for).not_to include("It is for:")
    end

    it "caps the page count it will ask for" do
      expect(prompt_for(page_count: 99)).to include("exactly #{described_class::MAX_PAGES} pages")
    end
  end
end
