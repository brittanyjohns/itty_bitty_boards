require "rails_helper"

# The presets this release actually retires and adds. Distinct from
# care_option_retirement_spec, which stubs DEPRECATED_CARE_OPTIONS to test the
# MECHANISM and must keep passing once these particular retirements are
# finished. This file asserts the current content, and is expected to change
# when the content does.
RSpec.describe "care preset reshape" do
  let(:user) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }
  let(:profile) do
    Profile.create!(profileable: child, username: "reshape-spec", slug: "reshape-spec")
  end

  def offered(section_key, field_key)
    Profile.care_registry_view[:sections]
           .find { |s| s[:key] == section_key }[:fields]
           .find { |f| f[:key] == field_key }[:options]
  end

  def store(section_key, values)
    profile.update!(
      settings: { "care" => { "sections" => { section_key => { "values" => values } } } },
    )
    profile.reload.settings.dig("care", "sections", section_key, "values")
  end

  describe "retired options" do
    it "no longer offers them in the editor" do
      expect(offered("communication", "methods"))
        .to eq(%w[aac_device aac_book sign gestures some_speech eye_gaze partner_assisted])
      expect(offered("communication", "help_level"))
        .to eq(%w[independent needs_prompts partner_required])
      expect(offered("transportation", "seating"))
        .to eq(%w[harness car_seat booster wheelchair_securement])
    end

    it "still accepts them, so nobody loses an answer they already gave" do
      # The reason retirement is two-step at all. Without this, every profile
      # holding one of these would lose it on its next save for any reason.
      expect(store("communication", "methods" => %w[echolalia writing facial_expressions]))
        .to eq("methods" => %w[echolalia writing facial_expressions])
      expect(store("communication", "help_level" => "hand_over_hand"))
        .to eq("help_level" => "hand_over_hand")
      expect(store("transportation", "seating" => %w[front_seat_only]))
        .to eq("seating" => %w[front_seat_only])
    end

    it "keeps the ones that change what a helper physically does" do
      # aac_book matters when the device is dead; partner_assisted and eye_gaze
      # are access methods. Cutting these would lose real information.
      expect(offered("communication", "methods"))
        .to include("aac_book", "partner_assisted", "eye_gaze")
    end

    it "maps each retirement to a replacement or an explicit nil" do
      Profile::DEPRECATED_CARE_OPTIONS.each do |section_key, fields|
        fields.each do |field_key, mapping|
          mapping.each do |retired, replacement|
            expect(retired).to be_a(String)
            next if replacement.nil?

            live = Profile::CARE_SECTIONS.dig(section_key, :fields)
                                         .find { |f| f[:key] == field_key }[:options]
            expect(live).to include(replacement),
              "#{section_key}.#{field_key}: #{retired} maps to #{replacement}, " \
              "which is not an option anyone can be moved onto"
          end
        end
      end
    end

    it "remaps echolalia onto some_speech without duplicating it" do
      store("communication", "methods" => %w[echolalia some_speech sign])
      remapped = CareOptionRemap.apply(profile.reload.settings["care"])
      expect(remapped.dig("sections", "communication", "values", "methods"))
        .to eq(%w[some_speech sign])
    end
  end

  describe "the sensory section" do
    it "is offered as its own section, not nested under meals" do
      keys = Profile.care_registry_view[:sections].map { |s| s[:key] }
      expect(keys).to include("sensory")
      expect(Profile::CARE_SECTIONS.dig("meals", :fields).map { |f| f[:key] })
        .not_to include("sound", "touch", "light")
    end

    it "stores its values through the sanitizer" do
      expect(
        store(
          "sensory",
          "sound" => %w[loud_noises_hurt uses_ear_defenders],
          "touch" => %w[ask_before_touching],
          "light" => %w[prefers_dim],
          "calming" => "Headphones and a quiet corner.",
        ),
      ).to eq(
        "sound" => %w[loud_noises_hurt uses_ear_defenders],
        "touch" => %w[ask_before_touching],
        "light" => %w[prefers_dim],
        "calming" => "Headphones and a quiet corner.",
      )
    end

    it "rejects an option outside its own registry" do
      expect(store("sensory", "sound" => %w[loud_noises_hurt smells]))
        .to eq("sound" => %w[loud_noises_hurt])
    end

    it "counts toward has_care_info? like any other section" do
      store("sensory", "calming" => "A quiet corner.")
      expect(profile.reload.has_care_info?).to be(true)
    end
  end

  # The endpoint must never offer a choice the sanitizer would drop — that is
  # the whole contract, and reshaping the registry is exactly when it could break.
  it "offers only options that survive a save" do
    sections = Profile.care_registry_view[:sections].each_with_object({}) do |section, acc|
      values = section[:fields].each_with_object({}) do |field, vals|
        case field[:type]
        when :multi_select then vals[field[:key]] = field[:options]
        when :single_select then vals[field[:key]] = field[:options].first
        when :short_text then vals[field[:key]] = "a note"
        end
      end
      acc[section[:key]] = { "enabled" => true, "values" => values }
    end

    profile.update!(settings: { "care" => { "sections" => sections } })
    stored = profile.reload.settings["care"]["sections"]

    Profile.care_registry_view[:sections].each do |section|
      section[:fields].each do |field|
        expected =
          case field[:type]
          when :multi_select then field[:options].first(Profile::MAX_CARE_MULTI_SELECT)
          when :single_select then field[:options].first
          when :short_text then "a note"
          end
        expect(stored.dig(section[:key], "values", field[:key])).to eq(expected),
          "#{section[:key]}.#{field[:key]} was offered but dropped on save"
      end
    end
  end
end
