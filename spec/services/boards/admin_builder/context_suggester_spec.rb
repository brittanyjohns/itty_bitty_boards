require "rails_helper"

RSpec.describe Boards::AdminBuilder::ContextSuggester do
  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  let(:valid) do
    { "name" => "At the Playground", "topic" => "the playground",
      "audience" => "an early communicator" }.to_json
  end

  # Never let a spec reach the real API.
  before { stub_ai(valid) }

  describe "#call" do
    it "returns a name, a topic and an audience" do
      expect(described_class.new(name: "At the Playground").call)
        .to eq({ name: "At the Playground", topic: "the playground", audience: "an early communicator" })
    end

    # The point of naming the board: an admin shouldn't have to invent one
    # before the AI will do anything.
    it "works from a topic alone, with no name" do
      expect(described_class.new(topic: "the playground").call[:name]).to eq("At the Playground")
    end

    it "works from words alone when the board has no name" do
      expect(described_class.new(name: "", words: "swing | noun\nslide | noun").call[:topic])
        .to eq("the playground")
    end

    it "refuses when there is nothing at all to work from" do
      expect { described_class.new(name: "  ", topic: "  ", words: "  ").call }
        .to raise_error(described_class::GenerationError, /name, a topic, or some words/)
    end
  end

  describe "cleanup of what the model returns" do
    # These are prompt fragments, not display copy — they get pasted into every
    # art prompt for the board.
    it "strips a trailing full stop" do
      stub_ai({ "topic" => "the playground.", "audience" => "an early communicator." }.to_json)

      result = described_class.new(name: "Playground").call
      expect(result[:topic]).to eq("the playground")
      expect(result[:audience]).to eq("an early communicator")
    end

    it "caps a runaway response" do
      stub_ai({ "name" => "n" * 500, "topic" => "x" * 500, "audience" => "y" * 500 }.to_json)

      result = described_class.new(name: "Playground").call
      expect(result[:name].length).to eq(described_class::MAX_NAME_LENGTH)
      expect(result[:topic].length).to eq(described_class::MAX_TOPIC_LENGTH)
      expect(result[:audience].length).to eq(described_class::MAX_AUDIENCE_LENGTH)
    end

    it "tolerates a missing name and audience" do
      stub_ai({ "topic" => "the playground" }.to_json)

      expect(described_class.new(name: "Playground").call)
        .to eq({ name: "", topic: "the playground", audience: "" })
    end
  end

  describe "failures" do
    it "raises when OpenAI returns nothing" do
      stub_ai("")

      expect { described_class.new(name: "Playground").call }
        .to raise_error(described_class::GenerationError, /no content/)
    end

    it "raises on unparseable JSON" do
      stub_ai("not json")

      expect { described_class.new(name: "Playground").call }
        .to raise_error(described_class::GenerationError, /Failed to parse/)
    end

    it "raises when the topic comes back empty" do
      stub_ai({ "topic" => "  ", "audience" => "someone" }.to_json)

      expect { described_class.new(name: "Playground").call }
        .to raise_error(described_class::GenerationError, /no usable topic/)
    end
  end

  describe "the prompt" do
    def prompt_for(**args)
      captured = nil
      allow(OpenAiClient).to receive(:new) do |opts|
        captured = opts[:messages].first[:content]
        instance_double(OpenAiClient, create_chat: { role: "assistant", content: valid })
      end
      described_class.new(**args).call
      captured
    end

    it "carries the board name" do
      expect(prompt_for(name: "At the Playground")).to include("The board is called: At the Playground")
    end

    it "carries the words already on the board" do
      expect(prompt_for(name: "Untitled", words: "swing | noun\nslide | noun"))
        .to include("Words already on it: swing, slide")
    end

    it "says so when the board has no name" do
      expect(prompt_for(name: "", words: "swing")).to include("no name yet")
    end

    it "carries a topic the admin already typed" do
      expect(prompt_for(topic: "the playground")).to include("It is about: the playground")
    end

    it "asks for a short, recognizable board name" do
      expect(prompt_for(name: "Playground")).to include("at most six words")
    end

    # The topic's whole job is to complete the art prompt's sentence.
    it "asks for a topic that fits the art prompt's sentence" do
      expect(prompt_for(name: "Playground")).to include("in the context of ___")
    end

    it "samples a long word list rather than sending all of it" do
      words = (1..60).map { |i| "word#{i} | noun" }.join("\n")
      prompt = prompt_for(name: "Big Board", words: words)

      expect(prompt).to include("word#{described_class::WORD_SAMPLE_SIZE}")
      expect(prompt).not_to include("word#{described_class::WORD_SAMPLE_SIZE + 1},")
    end
  end
end
