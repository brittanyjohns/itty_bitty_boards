require "rails_helper"

# The board form's "Age range" and the communicator form's "Age band" are two
# screens a user visits minutes apart, and each shipped its own hand-written
# list: `Any age / 2–3 / 4–6 / 7–10 / 11–14 / 15+` against
# `Under 4 / 4-6 / 7-10 / 11-14 / 15-18 / adult`. Two vocabularies for one
# concept, so anything reasoning about age across both — voice defaults, word
# suggestions — was reading incompatible answers, and `2-3` and `15+` matched
# no band at all. These assertions are about there being ONE list with ONE
# label per band, not about the strings themselves.
RSpec.describe CommunicatorProfile, ".age_band" do
  describe "the canonical vocabulary" do
    it "has a label key for every band, and no key for a band that does not exist" do
      expect(described_class::AGE_BAND_LABEL_KEYS.keys).to eq(described_class::AGE_BANDS)
    end

    it "resolves a real label for every band" do
      described_class::AGE_BANDS.each do |band|
        label = described_class.age_band_label(band)
        expect(label).to be_present
        expect(label).not_to include("translation missing")
      end
    end

    it "answers nil for a band it does not define rather than humanizing a guess" do
      expect(described_class.age_band_label("2-3")).to be_nil
      expect(described_class.age_band_label(nil)).to be_nil
    end

    it "serves options in band order, value and label together" do
      options = described_class.age_band_options

      expect(options.map { |o| o[:value] }).to eq(described_class::AGE_BANDS)
      expect(options.map { |o| o[:label] }).to all(be_present)
    end

    # Every band needs a voice, and the voice map is the other half of this
    # pair — a band added here and forgotten there hands a toddler an adult
    # voice.
    it "covers the same bands the voice default map does" do
      expect(described_class::AGE_BANDS).to match_array(VoiceService::DEFAULT_VOICE_BY_AGE_BAND.keys)
    end
  end

  describe ".band_for_age_range" do
    it "passes a canonical band through untouched" do
      described_class::AGE_BANDS.each do |band|
        expect(described_class.band_for_age_range(band)).to eq(band)
      end
    end

    # The two options that used to resolve to nothing at all: picking either
    # was the same as leaving the select alone.
    it "folds the board form's own ranges into a band" do
      expect(described_class.band_for_age_range("2-3")).to eq("under-4")
      expect(described_class.band_for_age_range("15+")).to eq("15-18")
    end

    it "folds the scenario form's ranges by their lower bound" do
      expect(described_class.band_for_age_range("0-3")).to eq("under-4")
      expect(described_class.band_for_age_range("7-9")).to eq("7-10")
      expect(described_class.band_for_age_range("19-21")).to eq("adult")
    end

    it "answers nil for blank or unparseable text rather than guessing a band" do
      expect(described_class.band_for_age_range(nil)).to be_nil
      expect(described_class.band_for_age_range("")).to be_nil
      expect(described_class.band_for_age_range("any age")).to be_nil
    end

    # `under-4` contains a 4, and reading that as the lower bound would land it
    # in `4-6` — the band it exists to sit below.
    it "prefers the canonical match over the digits inside it" do
      expect(described_class.band_for_age_range("under-4")).to eq("under-4")
    end
  end

  describe "resolving a profile from a legacy age_range" do
    it "gives the board form's ranges a real band, and with it a voice and young?" do
      profile = described_class.from_params(age_range: "2-3")

      expect(profile.age_band).to eq("under-4")
      expect(profile).to be_young
      expect(VoiceService.default_for_age_band(profile.age_band)).to eq("polly:kevin")
    end

    it "does not let a free-text range override an explicit age_band" do
      profile = described_class.from_params(age_band: "adult", age_range: "2-3")

      expect(profile.age_band).to eq("adult")
    end
  end

  describe ".age_range_prompt_text" do
    it "humanizes a canonical band so it reads as English in a prompt" do
      expect(described_class.age_range_prompt_text("under-4")).to eq("Under 4")
    end

    it "passes free text through, since it says more than the band it folds into" do
      expect(described_class.age_range_prompt_text("2-3")).to eq("2-3")
    end
  end
end
