require "rails_helper"

RSpec.describe AiBoardFormatter do
  let(:args) do
    {
      name: "Test Board",
      columns: 8,
      rows: 2,
      existing: [
        { word: "I" },
        { word: "want" },
        { word: "more" },
      ],
      maintain_existing: false,
    }
  end

  def stub_openai_response(content)
    fake_client = instance_double(OpenAiClient)
    allow(OpenAiClient).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:create_completion).and_return({ role: "assistant", content: content })
  end

  describe "part_of_speech vocabulary" do
    it "asks for the canonical Fitzgerald Key categories and no others" do
      captured = nil
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new) { |opts| captured = opts; fake_client }
      allow(fake_client).to receive(:create_completion).and_return({ role: "assistant", content: "{}" })

      described_class.call(**args)

      prompt = captured[:messages].last[:content]
      ColorHelper::PARTS_OF_SPEECH.each { |pos| expect(prompt).to include(pos) }
      # These are what the prompt used to offer as part_of_speech values. None
      # exist in ColorHelper::PARTS_OF_SPEECH, so background_color_for answered
      # "gray". ("phrase" still appears in the tile-sizing rules, which is why
      # this asserts on the POS list rather than the whole prompt.)
      expect(prompt).to include("Give every tile a part_of_speech")
      expect(prompt).not_to include("interjection")
      expect(prompt).not_to include("phrase")
    end

    it "keeps a part_of_speech that background_color_for actually understands" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "I", "frequency": "high", "part_of_speech": "important_function" }
          ]
        }
      JSON

      result = described_class.call(**args)

      expect(result["ordered_words"].first["part_of_speech"]).to eq("important_function")
    end

    it "drops a part_of_speech outside the canonical list rather than passing it through" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "I", "frequency": "high", "part_of_speech": "interjection" }
          ]
        }
      JSON

      result = described_class.call(**args)

      # nil, not "interjection" — the caller skips a nil POS, where an unknown
      # value would have reached background_color_for and painted the tile gray.
      expect(result["ordered_words"].first["part_of_speech"]).to be_nil
    end

    it "drops a frequency outside high/medium/low" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "I", "frequency": "constant", "part_of_speech": "pronoun" }
          ]
        }
      JSON

      expect(described_class.call(**args)["ordered_words"].first["frequency"]).to be_nil
    end
  end

  describe ".call" do
    it "returns a normalized hash for valid ordered_words JSON" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "I", "frequency": "high", "part_of_speech": "pronoun" },
            { "word": "want", "frequency": "high", "part_of_speech": "verb" },
            { "word": "more", "frequency": "high", "part_of_speech": "adjective" }
          ],
          "personable_explanation": "Easy to use.",
          "professional_explanation": "Core words first."
        }
      JSON

      result = described_class.call(**args)

      expect(result).to be_a(Hash)
      expect(result["ordered_words"].map { |w| w["word"] }).to eq(%w[I want more])
      expect(result["personable_explanation"]).to eq("Easy to use.")
      expect(result["professional_explanation"]).to eq("Core words first.")
    end

    it "strips ```json code fences" do
      stub_openai_response(<<~JSON)
        ```json
        {
          "ordered_words": [
            { "word": "I" }
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
            { "word": "I", },
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
            { "word": "I",    "position": [0,0], "frequency": "high" },
            { "word": "want", "position": [1,0], "frequency": "high" }
          ]
        }
      JSON

      result = described_class.call(**args)
      expect(result["ordered_words"].map { |w| w["word"] }).to eq(%w[I want])
    end

    it "drops items with blank words" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "" },
            { "word": "I" },
            { "word": "more" }
          ]
        }
      JSON

      result = described_class.call(**args)
      expect(result["ordered_words"].map { |w| w["word"] }).to eq(%w[I more])
    end

    # The model used to be told it could make "up to 2" tiles two cells wide,
    # and it took that permission every run. A size it cannot express is a size
    # it cannot get wrong — but an older response, or a legacy "grid" payload,
    # can still carry one, so normalize has to swallow it rather than pass it on.
    it "never returns a tile size, even when the model sends one" do
      stub_openai_response(<<~JSON)
        {
          "ordered_words": [
            { "word": "help",     "size": [2,1], "frequency": "high", "part_of_speech": "verb" },
            { "word": "all done", "size": [2,2], "frequency": "high", "part_of_speech": "social" }
          ]
        }
      JSON

      result = described_class.call(**args)

      expect(result["ordered_words"].map { |w| w["word"] }).to eq(["help", "all done"])
      result["ordered_words"].each { |w| expect(w).not_to have_key("size") }
    end

    it "never asks the model for a tile size" do
      captured = nil
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new) { |opts| captured = opts; fake_client }
      allow(fake_client).to receive(:create_completion).and_return({ role: "assistant", content: "{}" })

      described_class.call(**args)

      prompt = captured[:messages].last[:content]
      expect(prompt).to include("every tile is exactly one cell")
      expect(prompt).not_to include("[2, 1]")
      expect(prompt).not_to include("Tile sizing rules")
    end

    it "returns nil on unparseable output" do
      stub_openai_response("not json at all { ] }")
      expect(described_class.call(**args)).to be_nil
    end

    it "returns nil when the client returns blank content" do
      stub_openai_response(nil)
      expect(described_class.call(**args)).to be_nil
    end

    it "pins the response with a Structured Outputs schema that has no size" do
      captured = nil
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new) { |opts| captured = opts; fake_client }
      allow(fake_client).to receive(:create_completion).and_return({ content: '{"ordered_words": []}' })

      described_class.call(**args)

      schema = captured.dig(:response_format, :json_schema, :schema)
      expect(captured.dig(:response_format, :type)).to eq("json_schema")
      item_properties = schema.dig(:properties, "ordered_words", :items, :properties)
      expect(item_properties.keys).to contain_exactly("word", "frequency", "part_of_speech")
      expect(item_properties.dig("part_of_speech", :enum)).to eq(ColorHelper::PARTS_OF_SPEECH)
    end

    # create_completion swallows an API error into nil content, so a rejected
    # json_schema is indistinguishable from "the model had nothing to say".
    it "retries once without the schema when the schema call comes back empty" do
      formats = []
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new) { |opts| formats << opts[:response_format]; fake_client }
      allow(fake_client).to receive(:create_completion).and_return(
        { content: nil },
        { content: '{"ordered_words": [{ "word": "I" }]}' },
      )

      result = described_class.call(**args)

      expect(formats.map { |f| f[:type] }).to eq(["json_schema", "json_object"])
      expect(result["ordered_words"].map { |w| w["word"] }).to eq(["I"])
    end

    it "sends the shared AAC persona in the system slot" do
      captured = nil
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new) { |opts| captured = opts; fake_client }
      allow(fake_client).to receive(:create_completion).and_return({ content: "{}" })

      described_class.call(**args)

      expect(captured[:messages].first).to eq(role: "system", content: Prompts::Aac::SYSTEM_PROMPT)
    end

    it "asks for the same band order Ruby then enforces" do
      captured = nil
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new) { |opts| captured = opts; fake_client }
      allow(fake_client).to receive(:create_completion).and_return({ content: "{}" })

      described_class.call(**args)

      expect(captured[:messages].last[:content])
        .to include(Boards::TileArrangement::BAND_ORDER.join(", "))
    end
  end
end
