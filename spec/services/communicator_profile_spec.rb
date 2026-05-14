require "rails_helper"

RSpec.describe CommunicatorProfile do
  describe ".from_params" do
    it "returns nil when params are blank" do
      expect(described_class.from_params(nil)).to be_nil
      expect(described_class.from_params({})).to be_nil
    end

    it "returns nil when no usable profile fields are present" do
      expect(described_class.from_params({ "topic" => "Doctor Visit" })).to be_nil
    end

    it "builds a profile from string-keyed params" do
      profile = described_class.from_params({ "age" => "4", "aac_level" => "emerging" })
      expect(profile).to be_a(described_class)
      expect(profile.age).to eq(4)
      expect(profile.aac_level).to eq("emerging")
    end

    it "builds a profile from symbol-keyed params" do
      profile = described_class.from_params({ age_band: "15-18", vocab_type: "fringe" })
      expect(profile.age_band).to eq("15-18")
      expect(profile.vocab_type).to eq("fringe")
    end
  end

  describe "normalization" do
    it "derives an age band from a raw age" do
      expect(described_class.new(age: 4).age_band).to eq("4-6")
      expect(described_class.new(age: 9).age_band).to eq("7-10")
      expect(described_class.new(age: 13).age_band).to eq("11-14")
      expect(described_class.new(age: 17).age_band).to eq("15-18")
      expect(described_class.new(age: 40).age_band).to eq("adult")
    end

    it "prefers an explicit age_band over the derived one" do
      expect(described_class.new(age: 4, age_band: "adult").age_band).to eq("adult")
    end

    it "rejects out-of-range ages" do
      expect(described_class.new(age: 999).age).to be_nil
    end

    it "whitelists aac_level and ignores unknown values" do
      expect(described_class.new(aac_level: "EMERGING").aac_level).to eq("emerging")
      expect(described_class.new(aac_level: "wizard").aac_level).to be_nil
    end

    it "whitelists vocab_type and ignores unknown values" do
      expect(described_class.new(vocab_type: "Core").vocab_type).to eq("core")
      expect(described_class.new(vocab_type: "nonsense").vocab_type).to be_nil
    end

    it "falls back to the legacy age_range param" do
      expect(described_class.new(age_range: "7-10").age_band).to eq("7-10")
    end

    it "tolerates blank values" do
      profile = described_class.new(age: "", age_band: "", aac_level: "", vocab_type: "")
      expect(profile).to be_blank
    end
  end

  describe "#prompt_guidance" do
    it "is empty for a blank profile" do
      expect(described_class.new.prompt_guidance).to eq("")
    end

    it "emphasizes core vocabulary for emerging communicators" do
      guidance = described_class.new(age: 4, aac_level: "emerging").prompt_guidance
      expect(guidance).to match(/core vocabulary/i)
      expect(guidance).to match(/verbs/i)
      expect(guidance).to match(/emotions|social/i)
    end

    it "treats a young communicator as emerging even without an explicit aac_level" do
      expect(described_class.new(age: 5)).to be_emerging
      expect(described_class.new(age: 5).prompt_guidance).to match(/core vocabulary/i)
    end

    it "allows richer fringe vocabulary for proficient communicators" do
      guidance = described_class.new(age: 16, aac_level: "proficient").prompt_guidance
      expect(guidance).to match(/fringe/i)
      expect(guidance).not_to match(/roughly 80%/i)
    end

    it "includes vocab_type guidance when provided" do
      expect(described_class.new(age: 16, vocab_type: "core").prompt_guidance)
        .to match(/favor core vocabulary/i)
    end
  end
end
