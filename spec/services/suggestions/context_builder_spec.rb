require "rails_helper"

RSpec.describe Suggestions::ContextBuilder do
  let(:user) { create(:user) }
  let(:communicator) do
    create(:child_account, user: user, name: "Sam").tap do |c|
      c.update!(details: {
        "age_band" => "7-10",
        "aac_level" => "emerging",
        "glp_stage" => 2,
        "interests" => %w[trains drawing],
        "allergies" => "peanuts",
      })
    end
  end
  let(:profile) { create(:profile, profileable: communicator) }
  let(:entry) { Suggestions::Registry.fetch("profile_about_me") }

  describe ".build" do
    it "resolves every allow-listed key off the communicator" do
      result = described_class.build(entry, subject: profile)

      expect(result).to eq(
        name: "Sam",
        age_band: "7-10",
        aac_level: "emerging",
        glp_stage: 2,
        interests: "trains, drawing",
      )
    end

    it "drops keys whose values are blank rather than sending empty strings" do
      communicator.update!(details: { "age_band" => "7-10" })

      result = described_class.build(entry, subject: profile)

      expect(result.keys).to contain_exactly(:name, :age_band)
    end

    # The allow-list is the whole security model — a value present on the
    # record but absent from `context` must not appear in the output.
    it "cannot produce a key that is not allow-listed" do
      result = described_class.build(entry, subject: profile)

      expect(result).not_to have_key(:allergies)
      expect(result).not_to have_key(:vocab_type)
    end

    it "accepts allow-listed inline values and caps their length" do
      onboarding = Suggestions::Registry.fetch("onboarding_about_me")

      result = described_class.build(onboarding, inline: { name: "A" * 200 })

      expect(result[:name].length).to eq(Suggestions::Registry::INLINE_VALUE_MAX_CHARS)
    end

    it "ignores inline keys that are not allow-listed" do
      onboarding = Suggestions::Registry.fetch("onboarding_about_me")

      result = described_class.build(
        onboarding,
        inline: { name: "Sam", emergency_notes: "has seizures" },
      )

      expect(result).to eq(name: "Sam")
    end

    it "returns an empty hash when the profile has no communicator" do
      orphan = create(:profile, profileable: nil)

      expect(described_class.build(entry, subject: orphan)).to eq({})
    end
  end
end
