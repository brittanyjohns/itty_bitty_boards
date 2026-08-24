require "rails_helper"

RSpec.describe Boards::AiPageGenerator do
  let(:valid_ai_response) do
    {
      "name" => "Dinosaurs",
      "tiles" => [
        { "label" => "dinosaur" },
        { "label" => "T-rex" },
        { "label" => "fossil" },
        { "label" => "roar" },
        { "label" => "big" },
        { "label" => "scary" },
        { "label" => "teeth" },
        { "label" => "egg" },
        { "label" => "stomp" },
        { "label" => "dig" },
      ],
    }.to_json
  end

  before do
    allow_any_instance_of(OpenAiClient).to receive(:create_chat).and_return(
      { role: "assistant", content: valid_ai_response },
    )
  end

  describe "#call" do
    it "returns a blueprint with name and tiles" do
      result = described_class.new(interests: ["dinosaur"]).call
      expect(result[:name]).to eq("Dinosaurs")
      expect(result[:tiles]).to be_an(Array)
      expect(result[:tiles].size).to eq(10)
      expect(result[:tiles].first).to have_key(:label)
    end

    it "raises GenerationError with no interests" do
      expect {
        described_class.new(interests: []).call
      }.to raise_error(Boards::AiPageGenerator::GenerationError, /no interests/)
    end

    it "raises GenerationError when AI returns unparseable JSON" do
      allow_any_instance_of(OpenAiClient).to receive(:create_chat).and_return(
        { role: "assistant", content: "not json" },
      )

      expect {
        described_class.new(interests: ["dinosaur"]).call
      }.to raise_error(Boards::AiPageGenerator::GenerationError, /Failed to parse/)
    end

    it "raises GenerationError when AI returns too few tiles" do
      allow_any_instance_of(OpenAiClient).to receive(:create_chat).and_return(
        { role: "assistant", content: { "name" => "X", "tiles" => [{ "label" => "a" }] }.to_json },
      )

      expect {
        described_class.new(interests: ["dinosaur"]).call
      }.to raise_error(Boards::AiPageGenerator::GenerationError, /fewer than/)
    end

    it "raises GenerationError when AI returns no content" do
      allow_any_instance_of(OpenAiClient).to receive(:create_chat).and_return(
        { role: "assistant", content: nil },
      )

      expect {
        described_class.new(interests: ["dinosaur"]).call
      }.to raise_error(Boards::AiPageGenerator::GenerationError, /no content/)
    end

    it "caps tiles at the requested count" do
      many_tiles = (1..20).map { |i| { "label" => "word#{i}" } }
      allow_any_instance_of(OpenAiClient).to receive(:create_chat).and_return(
        { role: "assistant", content: { "name" => "Big", "tiles" => many_tiles }.to_json },
      )

      result = described_class.new(interests: ["test"], tile_count: 8).call
      expect(result[:tiles].size).to eq(8)
    end

    it "includes profile guidance in the prompt when provided" do
      profile = CommunicatorProfile.new(aac_level: "emerging", age_band: "4-6")
      expect_any_instance_of(OpenAiClient).to receive(:create_chat) do |client|
        messages = client.instance_variable_get(:@messages)
        user_prompt = messages.last[:content]
        expect(user_prompt).to include("core vocabulary")
        { role: "assistant", content: valid_ai_response }
      end

      described_class.new(interests: ["dinosaur"], profile: profile).call
    end

    # An interest page is the same job the admin Board Builder does, so it gets
    # the same brief. This prompt used to be one user message carrying its own
    # hand-written subset of the rules.
    it "sends the shared AAC system prompt and word rules" do
      expect_any_instance_of(OpenAiClient).to receive(:create_chat) do |client|
        messages = client.instance_variable_get(:@messages)

        expect(messages.map { |m| m[:role] }).to eq(%w[system user])
        expect(messages.first[:content]).to include(Prompts::Aac::SYSTEM_PROMPT)
        expect(messages.first[:content]).to include(Prompts::Aac::WORD_RULES)

        { role: "assistant", content: valid_ai_response }
      end

      described_class.new(interests: ["dinosaur"]).call
    end

    it "filters blank labels from the response" do
      tiles_with_blanks = [
        { "label" => "good" }, { "label" => "" }, { "label" => nil },
        { "label" => "word1" }, { "label" => "word2" }, { "label" => "word3" },
        { "label" => "word4" }, { "label" => "word5" }, { "label" => "word6" },
        { "label" => "word7" },
      ]
      allow_any_instance_of(OpenAiClient).to receive(:create_chat).and_return(
        { role: "assistant", content: { "name" => "Test", "tiles" => tiles_with_blanks }.to_json },
      )

      result = described_class.new(interests: ["test"]).call
      labels = result[:tiles].map { |t| t[:label] }
      expect(labels).not_to include("", nil)
    end
  end
end
