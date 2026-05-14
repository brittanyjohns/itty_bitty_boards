require "rails_helper"

RSpec.describe VoiceService, type: :service do
  describe ".get_voice_options" do
    subject(:options) { described_class.get_voice_options }

    it "returns an array of hashes" do
      expect(options).to be_an(Array)
      expect(options).not_to be_empty
    end

    it "includes all required keys" do
      options.each do |opt|
        expect(opt).to include(:label, :value, :provider)
      end
    end

    it "covers both polly and openai providers" do
      providers = options.map { |o| o[:provider] }.uniq
      expect(providers).to include("polly", "openai")
    end

    it "does not include nil values in the hash" do
      options.each do |opt|
        opt.each_value { |v| expect(v).not_to be_nil }
      end
    end
  end

  describe ".get_voice_labels" do
    it "returns an array of strings" do
      expect(described_class.get_voice_labels).to all(be_a(String))
    end

    it "includes known voice labels" do
      expect(described_class.get_voice_labels).to include("Kevin", "Joanna", "Alloy")
    end
  end

  describe ".get_voice_values" do
    it "returns an array of strings" do
      expect(described_class.get_voice_values).to all(be_a(String))
    end

    it "uses provider:name format" do
      described_class.get_voice_values.each do |v|
        expect(v).to match(/\A(polly|openai):.+\z/)
      end
    end
  end

  describe ".get_voice" do
    it "finds a voice by exact value" do
      voice = described_class.get_voice("polly:kevin")
      expect(voice).not_to be_nil
      expect(voice[:label]).to eq("Kevin")
    end

    it "finds a voice by label" do
      voice = described_class.get_voice("Alloy")
      expect(voice).not_to be_nil
      expect(voice[:value]).to eq("openai:alloy")
    end

    it "is case-insensitive for value lookup" do
      expect(described_class.get_voice("POLLY:KEVIN")).not_to be_nil
    end

    it "is case-insensitive for label lookup" do
      expect(described_class.get_voice("kevin")).not_to be_nil
    end

    it "returns nil for an unknown identifier" do
      expect(described_class.get_voice("polly:doesnotexist")).to be_nil
    end
  end

  describe ".normalize_voice" do
    it "returns 'polly:kevin' for a blank input" do
      expect(described_class.normalize_voice("")).to eq("polly:kevin")
      expect(described_class.normalize_voice("   ")).to eq("polly:kevin")
    end

    it "returns the value as-is when it already contains a colon" do
      expect(described_class.normalize_voice("polly:joanna")).to eq("polly:joanna")
    end

    it "converts a bare OpenAI voice name to the canonical value" do
      expect(described_class.normalize_voice("alloy")).to eq("openai:alloy")
    end

    it "converts a display label to the canonical value" do
      expect(described_class.normalize_voice("Coral")).to eq("openai:coral")
    end

    it "falls back to 'polly:kevin' for an unrecognised label" do
      expect(described_class.normalize_voice("UnknownVoiceName")).to eq("polly:kevin")
    end
  end

  describe ".voices_for_language" do
    it "returns English Polly voices plus OpenAI voices for 'en'" do
      values = described_class.voices_for_language("en")
      expect(values).to include("polly:kevin", "polly:amy", "openai:alloy")
      expect(values).not_to include("polly:lupe")
    end

    it "returns Spanish Polly voices plus OpenAI voices for 'es'" do
      values = described_class.voices_for_language("es")
      expect(values).to include("polly:lupe", "polly:lucia", "openai:alloy")
      expect(values).not_to include("polly:kevin")
    end

    it "matches on the ISO prefix of a BCP-47 code" do
      expect(described_class.voices_for_language("es-US")).to include("polly:lupe")
    end

    it "returns OpenAI voices for a language with no Polly voice" do
      values = described_class.voices_for_language("ja")
      expect(values).to include("openai:alloy")
      expect(values).not_to include("polly:kevin", "polly:lupe")
    end

    it "defaults to English when the code is blank" do
      expect(described_class.voices_for_language("")).to include("polly:kevin")
    end
  end

  describe ".synthesize_speech" do
    it "raises ArgumentError for an unrecognised voice" do
      expect {
        described_class.synthesize_speech(text: "hello", voice_value: "polly:unknown_voice_xyz")
      }.to raise_error(ArgumentError, /Invalid voice/)
    end

    it "raises ArgumentError for an unsupported provider prefix" do
      allow(described_class).to receive(:get_voice).and_return({ value: "aws:kevin", label: "Kevin" })
      expect {
        described_class.synthesize_speech(text: "hello", voice_value: "aws:kevin")
      }.to raise_error(ArgumentError, /Unsupported provider/)
    end
  end
end
