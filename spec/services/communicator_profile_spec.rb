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

  describe ".for" do
    let(:communicator) do
      FactoryBot.build(:child_account,
        details: { "aac_level" => "emerging", "age_band" => "4-6", "vocab_type" => "core" })
    end

    it "returns nil with no params and no communicator" do
      expect(described_class.for(params: nil, communicator: nil)).to be_nil
      expect(described_class.for(params: {})).to be_nil
    end

    it "builds entirely from the communicator's stored details" do
      profile = described_class.for(communicator: communicator)
      expect(profile.aac_level).to eq("emerging")
      expect(profile.age_band).to eq("4-6")
      expect(profile.vocab_type).to eq("core")
    end

    it "lets explicit params override stored values, field by field" do
      profile = described_class.for(params: { "aac_level" => "proficient" }, communicator: communicator)
      expect(profile.aac_level).to eq("proficient") # overridden
      expect(profile.age_band).to eq("4-6")         # stored value kept
      expect(profile.vocab_type).to eq("core")      # stored value kept
    end

    it "falls back to stored values when a param is blank" do
      profile = described_class.for(params: { "aac_level" => "" }, communicator: communicator)
      expect(profile.aac_level).to eq("emerging")
    end

    it "reads a stored age from details" do
      comm = FactoryBot.build(:child_account, details: { "age" => 5 })
      profile = described_class.for(communicator: comm)
      expect(profile.age).to eq(5)
      expect(profile.age_band).to eq("4-6")
    end

    it "returns nil when the communicator has no usable profile fields" do
      comm = FactoryBot.build(:child_account, details: { "interests" => ["trains"] })
      expect(described_class.for(communicator: comm)).to be_nil
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

  describe "#developing?" do
    it "is true for developing aac_level" do
      expect(described_class.new(aac_level: "developing")).to be_developing
    end

    it "is false for other levels" do
      expect(described_class.new(aac_level: "emerging")).not_to be_developing
      expect(described_class.new(aac_level: "proficient")).not_to be_developing
      expect(described_class.new).not_to be_developing
    end
  end

  describe "#young_teen?" do
    it "is true for age 11-14" do
      expect(described_class.new(age: 11)).to be_young_teen
      expect(described_class.new(age: 14)).to be_young_teen
    end

    it "is false for younger/older ages" do
      expect(described_class.new(age: 10)).not_to be_young_teen
      expect(described_class.new(age: 15)).not_to be_young_teen
    end

    it "falls back to age_band when no age" do
      expect(described_class.new(age_band: "11-14")).to be_young_teen
      expect(described_class.new(age_band: "7-10")).not_to be_young_teen
    end
  end

  describe "glp_stage (gestalt language processing)" do
    it "builds from params (string or integer) and stores an integer" do
      expect(described_class.from_params({ "glp_stage" => "3" }).glp_stage).to eq(3)
      expect(described_class.from_params({ glp_stage: 5 }).glp_stage).to eq(5)
    end

    it "makes a glp-only profile present (so .for returns it)" do
      comm = FactoryBot.build(:child_account, details: { "glp_stage" => 2 })
      profile = described_class.for(communicator: comm)
      expect(profile).to be_present
      expect(profile.glp_stage).to eq(2)
    end

    it "rejects out-of-range and non-numeric stages" do
      expect(described_class.new(glp_stage: 7).glp_stage).to be_nil
      expect(described_class.new(glp_stage: 0).glp_stage).to be_nil
      expect(described_class.new(glp_stage: "abc").glp_stage).to be_nil
      expect(described_class.new(glp_stage: nil).glp_stage).to be_nil
    end

    it "exposes stage-band predicates" do
      expect(described_class.new(glp_stage: 1)).to be_gestalt_early
      expect(described_class.new(glp_stage: 2)).to be_gestalt_early
      expect(described_class.new(glp_stage: 3)).to be_gestalt_emerging
      expect(described_class.new(glp_stage: 4)).to be_gestalt_emerging
      expect(described_class.new(glp_stage: 5)).to be_gestalt_advanced
      expect(described_class.new(glp_stage: 6)).to be_gestalt_advanced
    end

    it "leaves all gestalt predicates false when no stage is set" do
      profile = described_class.new(aac_level: "developing")
      expect(profile).not_to be_gestalt_early
      expect(profile).not_to be_gestalt_emerging
      expect(profile).not_to be_gestalt_advanced
    end

    describe "#prompt_guidance" do
      it "adds whole-phrase guidance for early stages (1-2)" do
        guidance = described_class.new(glp_stage: 1).prompt_guidance
        expect(guidance).to match(/gestalt language processor at NLA Stage 1/i)
        expect(guidance).to match(/whole familiar phrases|scripts/i)
        expect(guidance).to match(/avoid isolated vocabulary/i)
      end

      it "adds mixed word-and-phrase guidance for emerging stages (3-4)" do
        guidance = described_class.new(glp_stage: 4).prompt_guidance
        expect(guidance).to match(/NLA Stage 4/i)
        expect(guidance).to match(/single words with short phrases/i)
      end

      it "adds full-sentence guidance for advanced stages (5-6)" do
        guidance = described_class.new(glp_stage: 6).prompt_guidance
        expect(guidance).to match(/NLA Stage 6/i)
        expect(guidance).to match(/full sentences|verb tenses/i)
      end

      it "adds no gestalt guidance when glp_stage is unset (backward compatible)" do
        guidance = described_class.new(age: 4, aac_level: "emerging").prompt_guidance
        expect(guidance).not_to match(/gestalt|NLA Stage/i)
      end
    end
  end
end
