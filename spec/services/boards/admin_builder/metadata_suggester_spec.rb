require "rails_helper"

RSpec.describe Boards::AdminBuilder::MetadataSuggester do
  def ai_metadata(description: "A board for talking at the playground.", tags: ["playground"])
    { "description" => description, "tags" => tags }.to_json
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  before { stub_ai(ai_metadata) }

  def suggest(**overrides)
    described_class.new(
      **{ name: "At the Playground", topic: "the playground", labels: %w[swing slide run],
          vocabulary: %w[playground outdoor core] }.merge(overrides),
    ).call
  end

  describe "#call" do
    it "returns a description and tags" do
      expect(suggest).to eq({ description: "A board for talking at the playground.", tags: ["playground"] })
    end

    it "refuses to run with nothing to describe" do
      expect { described_class.new(name: "", topic: "", labels: [], vocabulary: []).call }
        .to raise_error(described_class::GenerationError, /name, a topic, or some words/)
    end
  end

  describe "cleanup of the description" do
    it "strips HTML, because three of four frontend surfaces render it as plain text" do
      stub_ai(ai_metadata(description: "<h2>Purpose</h2><p>A playground board.</p>"))

      expect(suggest[:description]).to eq("Purpose A playground board.")
    end

    it "truncates a runaway description" do
      stub_ai(ai_metadata(description: "word " * 200))

      expect(suggest[:description].length).to be <= described_class::MAX_DESCRIPTION_LENGTH
    end
  end

  describe "cleanup of the tags" do
    it "normalizes casing and whitespace" do
      stub_ai(ai_metadata(tags: ["  PlayGround  ", "Outdoor   Play"]))

      expect(suggest(vocabulary: ["playground", "outdoor play"])[:tags]).to eq(["playground", "outdoor play"])
    end

    it "keeps at most two tags that aren't already in the vocabulary" do
      stub_ai(ai_metadata(tags: %w[playground new_one new_two new_three]))

      expect(suggest(vocabulary: %w[playground])[:tags]).to eq(%w[playground new_one new_two])
    end

    it "keeps more than two tags when they all come from the vocabulary" do
      stub_ai(ai_metadata(tags: %w[playground outdoor core]))

      expect(suggest(vocabulary: %w[playground outdoor core])[:tags]).to eq(%w[playground outdoor core])
    end

    it "caps the total" do
      stub_ai(ai_metadata(tags: %w[a b c d e f g h]))

      expect(suggest(vocabulary: %w[a b c d e f g h])[:tags].size).to eq(described_class::MAX_TAGS)
    end

    it "drops a tag longer than the cap and blank entries" do
      stub_ai(ai_metadata(tags: ["playground", "x" * 40, "  ", nil]))

      expect(suggest(vocabulary: %w[playground])[:tags]).to eq(%w[playground])
    end

    it "drops a repeated tag" do
      stub_ai(ai_metadata(tags: %w[playground Playground]))

      expect(suggest(vocabulary: %w[playground])[:tags]).to eq(%w[playground])
    end

    it "reads the live public vocabulary when none is passed" do
      allow(Board).to receive(:public_boards_tags).and_return(%w[zebra apple])
      stub_ai(ai_metadata(tags: %w[apple]))

      expect(suggest(vocabulary: nil)[:tags]).to eq(%w[apple])
      expect(Board).to have_received(:public_boards_tags)
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

    it "raises when neither a description nor a tag came back" do
      stub_ai(ai_metadata(description: "  ", tags: []))
      expect { suggest }.to raise_error(described_class::GenerationError, /nothing usable/)
    end
  end

  describe "the prompt" do
    def prompt_for(**args)
      captured = nil
      allow(OpenAiClient).to receive(:new) do |opts|
        captured = opts[:messages].first[:content]
        instance_double(OpenAiClient, create_chat: { role: "assistant", content: ai_metadata })
          .tap { |double| allow(double).to receive(:instance_variable_set) }
      end
      described_class.new(**{ name: "At the Playground", topic: "the playground",
                              labels: %w[swing slide], vocabulary: %w[zebra apple] }.merge(args)).call
      captured
    end

    it "hands the model the vocabulary, sorted" do
      expect(prompt_for).to include("apple, zebra")
    end

    it "sorts and truncates a large vocabulary deterministically" do
      big = (1..100).map { |n| format("tag%03d", n) }

      prompt = prompt_for(vocabulary: big.shuffle)
      expect(prompt).to include("tag001")
      expect(prompt).not_to include("tag061")
    end

    it "asks for plain text and no word list" do
      expect(prompt_for).to include("Plain text")
      expect(prompt_for).to include("Do not list the words")
    end

    it "states both tag limits" do
      expect(prompt_for).to include("at most #{described_class::MAX_TAGS}")
      expect(prompt_for).to include("at most #{described_class::MAX_NEW_TAGS}")
    end

    it "includes the audience and page names only when given" do
      expect(prompt_for(audience: "a preschooler")).to include("It is for: a preschooler")
      expect(prompt_for(page_names: ["Food"])).to include("Food")
      expect(prompt_for).not_to include("It is for:")
    end
  end
end
