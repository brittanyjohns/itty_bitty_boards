require "rails_helper"

RSpec.describe AacWordCategorizer, type: :service do
  describe ".normalize" do
    it "downcases and strips whitespace" do
      expect(described_class.normalize("  Hello  ")).to eq("hello")
    end

    it "collapses internal whitespace" do
      expect(described_class.normalize("all   done")).to eq("all done")
    end

    it "handles nil gracefully" do
      expect(described_class.normalize(nil)).to eq("")
    end

    it "returns an empty string unchanged" do
      expect(described_class.normalize("")).to eq("")
    end
  end

  describe ".safe_json_parse" do
    it "parses a valid JSON string" do
      result = described_class.safe_json_parse('{"part_of_speech":"noun"}')
      expect(result).to eq({ "part_of_speech" => "noun" })
    end

    it "strips markdown code fences before parsing" do
      result = described_class.safe_json_parse("```json\n{\"part_of_speech\":\"verb\"}\n```")
      expect(result).to eq({ "part_of_speech" => "verb" })
    end

    it "extracts the first JSON object from surrounding text" do
      result = described_class.safe_json_parse('Sure! Here is your answer: {"part_of_speech":"adjective"} done.')
      expect(result).to eq({ "part_of_speech" => "adjective" })
    end

    it "returns nil for unparseable input" do
      expect(described_class.safe_json_parse("not json at all")).to be_nil
    end

    it "returns nil for an empty string" do
      expect(described_class.safe_json_parse("")).to be_nil
    end
  end

  describe ".extract_content_text" do
    it "returns a plain string as-is" do
      expect(described_class.extract_content_text("hello")).to eq("hello")
    end

    it "extracts content from a symbol-keyed hash" do
      expect(described_class.extract_content_text({ role: "assistant", content: "hi" })).to eq("hi")
    end

    it "extracts content from a string-keyed hash" do
      expect(described_class.extract_content_text({ "content" => "bye" })).to eq("bye")
    end

    it "extracts from a nested OpenAI-style response" do
      response = { "choices" => [{ "message" => { "content" => "nested" } }] }
      expect(described_class.extract_content_text(response)).to eq("nested")
    end

    it "falls back to to_s for unknown shapes" do
      expect(described_class.extract_content_text(42)).to eq("42")
    end
  end

  describe ".extract_pos" do
    it "returns the part_of_speech from a valid JSON response string" do
      json = '{"part_of_speech":"noun"}'
      expect(described_class.extract_pos(json)).to eq("noun")
    end

    it "returns 'default' for a blank response" do
      expect(described_class.extract_pos("")).to eq("default")
      expect(described_class.extract_pos(nil)).to eq("default")
    end

    it "returns 'default' when part_of_speech is not in the allowed list" do
      json = '{"part_of_speech":"unknown_category"}'
      expect(described_class.extract_pos(json)).to eq("default")
    end

    it "accepts all valid PARTS_OF_SPEECH values" do
      AacWordCategorizer::PARTS_OF_SPEECH.each do |pos|
        json = "{\"part_of_speech\":\"#{pos}\"}"
        expect(described_class.extract_pos(json)).to eq(pos)
      end
    end
  end

  describe ".categorize" do
    context "with a blank input" do
      it "returns 'default'" do
        expect(described_class.categorize("")).to eq("default")
        expect(described_class.categorize("   ")).to eq("default")
      end
    end

    context "when a local override exists" do
      it "returns the override without calling the LLM" do
        expect(described_class).not_to receive(:call_llm)
        expect(described_class.categorize("please")).to eq("social")
      end

      it "matches overrides case-insensitively via normalize" do
        expect(described_class.categorize("NO")).to eq("important_function")
      end

      it "returns 'social' for 'more'" do
        expect(described_class.categorize("more")).to eq("social")
      end

      it "returns 'question' for 'what'" do
        expect(described_class.categorize("what")).to eq("question")
      end

      it "returns 'determiner' for 'the'" do
        expect(described_class.categorize("the")).to eq("determiner")
      end
    end

    context "when the result is cached" do
      let(:cache_key) { "aac_pos:v1:#{Digest::SHA256.hexdigest("apple")}" }

      it "returns the cached value without calling the LLM" do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return("noun")
        expect(described_class).not_to receive(:call_llm)
        expect(described_class.categorize("apple")).to eq("noun")
      end

      it "ignores a cached value that is not in PARTS_OF_SPEECH" do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return("garbage")
        allow(Rails.cache).to receive(:write)
        expect(described_class).to receive(:call_llm).and_return('{"part_of_speech":"verb"}')
        described_class.categorize("apple")
      end
    end

    context "when the LLM must be called" do
      let(:cache_key) { "aac_pos:v1:#{Digest::SHA256.hexdigest("bicycle")}" }

      before { allow(Rails.cache).to receive(:read).and_return(nil) }

      it "calls the LLM, writes the result to cache, and returns it" do
        expect(described_class).to receive(:call_llm).and_return('{"part_of_speech":"noun"}')
        expect(Rails.cache).to receive(:write).with(cache_key, "noun", anything)
        result = described_class.categorize("bicycle")
        expect(result).to eq("noun")
      end

      it "returns 'default' when the LLM call fails" do
        allow(Rails.cache).to receive(:write)
        expect(described_class).to receive(:call_llm).and_return(nil)
        expect(described_class.categorize("bicycle")).to eq("default")
      end
    end
  end
end
