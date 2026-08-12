require "rails_helper"

# Retiring a care option is the one edit that can silently destroy a parent's
# data: sanitize_care_settings is a before_save, so it re-cleans the whole blob
# every time a profile is saved for ANY reason. Delete an option from
# CARE_SECTIONS and the next avatar upload erases that answer everywhere.
#
# DEPRECATED_CARE_OPTIONS is what makes retirement survivable. These specs stub
# it rather than depending on whatever happens to be retired today, so they keep
# testing the mechanism after the current retirements are finished and removed.
RSpec.describe "retiring a care option" do
  let(:user) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }
  let(:profile) do
    Profile.create!(profileable: child, username: "retire-spec", slug: "retire-spec")
  end

  # "some_speech" retired in favour of "gestures"; "echolalia" retired with no
  # replacement. Both are real keys, so the fixture stays valid.
  let(:deprecations) do
    { "communication" => { "methods" => { "some_speech" => "gestures", "echolalia" => nil } } }
  end

  before do
    stub_const("Profile::DEPRECATED_CARE_OPTIONS", deprecations)
  end

  def store_methods(methods)
    profile.update!(
      settings: {
        "care" => {
          "sections" => { "communication" => { "values" => { "methods" => methods } } },
        },
      },
    )
    profile.reload.settings.dig("care", "sections", "communication", "values", "methods")
  end

  describe "the sanitizer" do
    it "keeps a retired option a parent already had" do
      # The whole point. Without this, saving the profile for any reason at all
      # would drop the answer.
      expect(store_methods(%w[some_speech sign])).to eq(%w[some_speech sign])
    end

    it "keeps one that has no replacement" do
      expect(store_methods(%w[echolalia])).to eq(%w[echolalia])
    end

    it "still rejects an option that was never in the registry" do
      expect(store_methods(%w[telepathy sign])).to eq(%w[sign])
    end

    it "survives a re-save, which is what a before_save would otherwise break" do
      store_methods(%w[some_speech])
      profile.update!(username: "retire-spec-renamed")
      expect(
        profile.reload.settings.dig("care", "sections", "communication", "values", "methods"),
      ).to eq(%w[some_speech])
    end
  end

  describe "the registry endpoint" do
    it "stops offering a retired option while still accepting it" do
      offered = Profile.care_registry_view[:sections]
                       .find { |s| s[:key] == "communication" }[:fields]
                       .find { |f| f[:key] == "methods" }[:options]

      expect(offered).not_to include("some_speech", "echolalia")
      expect(offered).to include("sign", "gestures")

      field = Profile::CARE_SECTIONS.dig("communication", :fields)
                                    .find { |f| f[:key] == "methods" }
      expect(Profile.accepted_care_options("communication", field))
        .to include("some_speech", "echolalia")
    end
  end

  describe "CareOptionRemap" do
    it "reports what a profile still holds" do
      store_methods(%w[some_speech sign echolalia])
      expect(CareOptionRemap.hits_for(profile.reload)).to contain_exactly(
        "communication.methods.some_speech",
        "communication.methods.echolalia",
      )
    end

    it "reports nothing for a profile holding only live options" do
      store_methods(%w[sign])
      expect(CareOptionRemap.hits_for(profile.reload)).to be_empty
    end

    it "moves a retired option onto its replacement" do
      store_methods(%w[some_speech sign])
      result = CareOptionRemap.apply(profile.reload.settings["care"])
      expect(result.dig("sections", "communication", "values", "methods"))
        .to eq(%w[gestures sign])
    end

    it "collapses rather than duplicating when the replacement is already there" do
      store_methods(%w[some_speech gestures])
      result = CareOptionRemap.apply(profile.reload.settings["care"])
      expect(result.dig("sections", "communication", "values", "methods")).to eq(%w[gestures])
    end

    it "drops a retired option that has no replacement" do
      store_methods(%w[echolalia sign])
      result = CareOptionRemap.apply(profile.reload.settings["care"])
      expect(result.dig("sections", "communication", "values", "methods")).to eq(%w[sign])
    end

    it "removes the field entirely when nothing survives" do
      store_methods(%w[echolalia])
      result = CareOptionRemap.apply(profile.reload.settings["care"])
      expect(result.dig("sections", "communication", "values")).not_to have_key("methods")
    end

    it "returns nil when there is nothing to change, so the task skips the row" do
      store_methods(%w[sign])
      expect(CareOptionRemap.apply(profile.reload.settings["care"])).to be_nil
    end

    it "does not mutate the blob it was given" do
      store_methods(%w[some_speech])
      care = profile.reload.settings["care"]
      before = care.deep_dup
      CareOptionRemap.apply(care)
      expect(care).to eq(before)
    end

    it "leaves a remapped blob acceptable to the sanitizer" do
      # The remap output has to survive the very callback that made this
      # mechanism necessary.
      store_methods(%w[some_speech echolalia])
      remapped = CareOptionRemap.apply(profile.reload.settings["care"])

      profile.update!(settings: profile.settings.merge("care" => remapped))
      expect(
        profile.reload.settings.dig("care", "sections", "communication", "values", "methods"),
      ).to eq(%w[gestures])
    end
  end

  describe "with nothing retired (the steady state)" do
    before { stub_const("Profile::DEPRECATED_CARE_OPTIONS", {}) }

    it "offers exactly what it accepts" do
      field = Profile::CARE_SECTIONS.dig("communication", :fields)
                                    .find { |f| f[:key] == "methods" }
      expect(Profile.accepted_care_options("communication", field)).to eq(field[:options])
      expect(Profile.offered_care_options("communication", field)).to eq(field[:options])
    end

    it "reports and remaps nothing" do
      store_methods(%w[sign])
      expect(CareOptionRemap.hits_for(profile.reload)).to be_empty
      expect(CareOptionRemap.apply(profile.reload.settings["care"])).to be_nil
    end
  end
end
