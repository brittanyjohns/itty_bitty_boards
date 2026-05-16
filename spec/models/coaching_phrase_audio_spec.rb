require "rails_helper"

RSpec.describe CoachingPhraseAudio, type: :model do
  describe ".phrase_key_for" do
    it "is deterministic for the same inputs" do
      a = described_class.phrase_key_for(text: "Hello", voice: "polly:kevin")
      b = described_class.phrase_key_for(text: "Hello", voice: "polly:kevin")
      expect(a).to eq(b)
    end

    it "differs across voices" do
      a = described_class.phrase_key_for(text: "Hello", voice: "polly:kevin")
      b = described_class.phrase_key_for(text: "Hello", voice: "polly:joanna")
      expect(a).not_to eq(b)
    end

    it "differs across languages" do
      a = described_class.phrase_key_for(text: "Hello", voice: "polly:kevin", language: "en")
      b = described_class.phrase_key_for(text: "Hello", voice: "polly:kevin", language: "es")
      expect(a).not_to eq(b)
    end

    it "normalizes voice case and trims text" do
      a = described_class.phrase_key_for(text: " Hello ", voice: "Polly:Kevin")
      b = described_class.phrase_key_for(text: "Hello", voice: "polly:kevin")
      expect(a).to eq(b)
    end
  end

  describe ".find_or_generate!" do
    let(:io) { StringIO.new("FAKE_MP3_BYTES") }

    before do
      allow(described_class).to receive(:synthesize).and_return(io)
    end

    it "creates a new record + attaches audio on first call" do
      expect {
        record = described_class.find_or_generate!(text: "Hi", voice: "polly:kevin")
        expect(record.audio.attached?).to be true
        expect(record.text).to eq("Hi")
        expect(record.voice).to eq("polly:kevin")
      }.to change(described_class, :count).by(1)
    end

    it "returns the existing record without re-synthesizing on second call" do
      first = described_class.find_or_generate!(text: "Hi", voice: "polly:kevin")
      expect(described_class).not_to receive(:synthesize)
      second = described_class.find_or_generate!(text: "Hi", voice: "polly:kevin")
      expect(second.id).to eq(first.id)
    end

    it "treats different voices as separate cache entries" do
      a = described_class.find_or_generate!(text: "Hi", voice: "polly:kevin")
      b = described_class.find_or_generate!(text: "Hi", voice: "polly:joanna")
      expect(a.id).not_to eq(b.id)
      expect(described_class.count).to eq(2)
    end

    it "returns nil when synthesis fails" do
      allow(described_class).to receive(:synthesize).and_return(nil)
      result = described_class.find_or_generate!(text: "Hi", voice: "polly:kevin")
      expect(result).to be_nil
    end
  end
end
