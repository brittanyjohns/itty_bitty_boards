require "rails_helper"

RSpec.describe Boards::AdminBuilder::PageDrafter do
  let(:root) { Boards::AdminBuilder::Plan::ROOT_KEY }

  def ai_tiles(*tiles)
    { "tiles" => tiles }.to_json
  end

  def tile(label, pos, links_to: nil)
    { "label" => label, "part_of_speech" => pos }.tap do |raw|
      raw["links_to"] = links_to if links_to
    end
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  # The drafter's own prompt is the USER message — Drafting prepends a shared
  # system message ahead of it.
  def captured_prompt(&block)
    captured_opts(&block)[:messages].find { |message| message[:role] == "user" }[:content]
  end

  def captured_opts
    opts = nil
    allow(OpenAiClient).to receive(:new).and_wrap_original do |original, **kwargs|
      opts = kwargs
      original.call(**kwargs)
    end
    yield
    opts
  end

  let(:four_tiles) do
    ai_tiles(
      tile("apple", "noun"),
      tile("hungry", "adjective"),
      tile("eat", "verb"),
      tile("back", "social", links_to: root),
    )
  end

  # Never let a spec reach the real API.
  before { stub_ai(four_tiles) }

  describe "#call" do
    # Band order, not the model's: the drafted order is the grid layout. The
    # back tile carries a link, so it sorts into the navigation band last — which
    # is where BackTileAlignment expects to find it.
    it "returns labels with parts of speech, grouped, with the back link last" do
      result = described_class.new(page_name: "Food", tile_count: 4).call

      expect(result).to eq([
        { label: "eat", part_of_speech: "verb" },
        { label: "hungry", part_of_speech: "adjective" },
        { label: "apple", part_of_speech: "noun" },
        { label: "back", part_of_speech: "social", links_to: root },
      ])
    end

    it "refuses to draft without a page title" do
      expect { described_class.new(page_name: "  ", tile_count: 4).call }
        .to raise_error(described_class::GenerationError, /page a name/)
    end

    # The key is an identifier, so it stands in only when there's no title.
    it "falls back to the page key when the name is blank" do
      expect { described_class.new(page_name: "", page_key: "my_turn", tile_count: 4).call }
        .not_to raise_error
    end

    it "trims a response longer than the grid" do
      stub_ai(ai_tiles(
                tile("apple", "noun"), tile("hungry", "adjective"),
                tile("eat", "verb"), tile("back", "social", links_to: root), tile("pear", "noun")
              ))

      expect(described_class.new(page_name: "Food", tile_count: 4).call.size).to eq(4)
    end

    # This only fills a textarea, so a short draft is survivable.
    it "returns a short draft rather than raising" do
      stub_ai(ai_tiles(tile("apple", "noun")))

      expect(described_class.new(page_name: "Food", tile_count: 9).call.size).to eq(1)
    end

    it "raises when nothing in the response is usable" do
      stub_ai({ "tiles" => [] }.to_json)

      expect { described_class.new(page_name: "Food", tile_count: 4).call }
        .to raise_error(described_class::GenerationError, /no usable words/)
    end

    it "raises on an unparseable response" do
      stub_ai("not json")

      expect { described_class.new(page_name: "Food", tile_count: 4).call }
        .to raise_error(described_class::GenerationError, /parse/)
    end
  end

  describe "the prompt" do
    it "is built around the page title, with the board topic as context" do
      prompt = captured_prompt do
        described_class.new(page_name: "Food", tile_count: 4, topic: "the playground", audience: "a preschooler").call
      end

      expect(prompt).to include("The page is about: Food")
      expect(prompt).to include("a board about: the playground")
      expect(prompt).to include("It is for: a preschooler")
      expect(prompt).to include("EXACTLY 4 tiles")
      expect(prompt).to include(root)
    end

    it "omits the board context when there is none" do
      prompt = captured_prompt { described_class.new(page_name: "Food", tile_count: 4).call }

      expect(prompt).not_to include("a board about:")
      expect(prompt).not_to include("It is for:")
    end

    it "carries the shared word rules and the band order" do
      prompt = captured_prompt { described_class.new(page_name: "Food", tile_count: 4).call }

      expect(prompt).to include(Boards::AdminBuilder::Drafting::WORD_RULES.rstrip)
      expect(prompt).to include(Boards::AdminBuilder::TileArrangement::BAND_ORDER.join(", "))
      # A page of nouns is the failure this drafter is most prone to.
      expect(prompt).to include("what you DO there and what it")
    end

    it "is sent behind the shared system prompt, under a json schema" do
      opts = captured_opts { described_class.new(page_name: "Food", tile_count: 4).call }

      expect(opts[:messages].map { |message| message[:role] }).to eq(%w[system user])
      expect(opts[:messages].first[:content]).to eq(Boards::AdminBuilder::Drafting::SYSTEM_PROMPT)
      expect(opts.dig(:response_format, :json_schema, :name)).to eq("aac_page_word_list")
    end
  end

  describe "cleanup of what the model returns" do
    # `images.label` is a lowercase matching key, so "Apple" and "apple" are one
    # symbol — a draft that fails validation on arrival is worse than a short one.
    it "drops casing-only repeats" do
      stub_ai(ai_tiles(tile("apple", "noun"), tile("Apple", "noun"), tile("eat", "verb")))

      expect(described_class.new(page_name: "Food", tile_count: 4).call.map { |t| t[:label] })
        .to eq(%w[eat apple])
    end

    it "folds a snake_cased label back to display text" do
      stub_ai(ai_tiles(tile("all_done", "social")))

      expect(described_class.new(page_name: "Food", tile_count: 4).call.first[:label]).to eq("all done")
    end

    it "falls back to 'default' for a part of speech off the list" do
      stub_ai(ai_tiles(tile("apple", "fruit")))

      expect(described_class.new(page_name: "Food", tile_count: 4).call.first[:part_of_speech]).to eq("default")
    end

    it "tolerates 'word' as an alias for 'label'" do
      stub_ai({ "tiles" => [{ "word" => "apple", "part_of_speech" => "noun" }] }.to_json)

      expect(described_class.new(page_name: "Food", tile_count: 1).call)
        .to eq([{ label: "apple", part_of_speech: "noun" }])
    end

    # This drafter is given one page and knows no other page's key, so a link
    # anywhere but back would name a page it can't vouch for — and PlanValidator
    # rejects a link to a key that isn't in the set.
    it "keeps only the back link and drops any other link target" do
      stub_ai(ai_tiles(tile("drinks", "noun", links_to: "drinks"), tile("back", "social", links_to: root)))

      result = described_class.new(page_name: "Food", tile_count: 4).call
      expect(result.first).not_to have_key(:links_to)
      expect(result.last[:links_to]).to eq(root)
    end
  end
end
