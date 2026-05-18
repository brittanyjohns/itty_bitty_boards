require "rails_helper"

RSpec.describe AiBoardFormatter do
  let(:args) do
    {
      name: "Test Board",
      columns: 8,
      rows: 2,
      existing: [
        { word: "I",    size: [1, 1] },
        { word: "want", size: [1, 1] },
        { word: "more", size: [1, 1] },
      ],
      maintain_existing: false,
    }
  end

  def stub_openai_response(content)
    fake_client = instance_double(OpenAiClient)
    allow(OpenAiClient).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:create_completion).and_return({ role: "assistant", content: content })
  end

  describe ".call" do
    it "returns a normalized hash for valid ordered_words JSON" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "I", "size": [1,1], "frequency": "high", "part_of_speech": "pronoun" },
            { "word": "want", "size": [1,1], "frequency": "high", "part_of_speech": "verb" },
            { "word": "more", "size": [1,1], "frequency": "high", "part_of_speech": "adjective" }
          ],
          "personable_explanation": "Easy to use.",
          "professional_explanation": "Core words first."
        }
      JSON

      result = described_class.call(**args)

      expect(result).to be_a(Hash)
      expect(result["ordered_words"].map { |w| w["word"] }).to eq(%w[I want more])
      expect(result["ordered_words"].first["size"]).to eq([1, 1])
      expect(result["personable_explanation"]).to eq("Easy to use.")
      expect(result["professional_explanation"]).to eq("Core words first.")
    end

    it "strips ```json code fences" do
      stub_openai_response(<<~JSON)
        ```json
        {
          "ordered_words": [
            { "word": "I", "size": [1,1] }
          ]
        }
        ```
      JSON

      result = described_class.call(**args)
      expect(result["ordered_words"].length).to eq(1)
      expect(result["ordered_words"].first["word"]).to eq("I")
    end

    it "tolerates trailing commas" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "I", "size": [1,1], },
          ],
        }
      JSON

      result = described_class.call(**args)
      expect(result["ordered_words"].length).to eq(1)
    end

    it "falls back to legacy 'grid' key when ordered_words is missing" do
      stub_openai_response(<<~JSON)
        {
          "grid": [
            { "word": "I",    "position": [0,0], "size": [1,1], "frequency": "high" },
            { "word": "want", "position": [1,0], "size": [1,1], "frequency": "high" }
          ]
        }
      JSON

      result = described_class.call(**args)
      expect(result["ordered_words"].map { |w| w["word"] }).to eq(%w[I want])
    end

    it "drops items with blank words and clamps sizes below 1" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "",    "size": [1,1] },
            { "word": "I",   "size": [0,0] },
            { "word": "more","size": [2,1] }
          ]
        }
      JSON

      result = described_class.call(**args)
      expect(result["ordered_words"].length).to eq(2)
      expect(result["ordered_words"][0]).to include("word" => "I", "size" => [1, 1])
      expect(result["ordered_words"][1]).to include("word" => "more", "size" => [2, 1])
    end

    it "returns nil on unparseable output" do
      stub_openai_response("not json at all { ] }")
      expect(described_class.call(**args)).to be_nil
    end

    it "returns nil when the client returns blank content" do
      stub_openai_response(nil)
      expect(described_class.call(**args)).to be_nil
    end

    it "passes response_format: json_object to OpenAiClient" do
      fake_client = instance_double(OpenAiClient)
      allow(fake_client).to receive(:create_completion).and_return({ content: '{"ordered_words": []}' })
      expect(OpenAiClient).to receive(:new).with(hash_including(response_format: { type: "json_object" })).and_return(fake_client)

      described_class.call(**args)
    end
  end
end
