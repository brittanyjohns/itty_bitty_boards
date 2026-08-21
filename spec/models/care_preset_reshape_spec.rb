require "rails_helper"

# The SHAPE of the care registry, as opposed to care_option_retirement_spec.rb,
# which stubs DEPRECATED_CARE_OPTIONS to test the retirement mechanism and must
# keep passing whatever the presets happen to say.
#
# These are the rules a new field has to follow, written as assertions so the
# next person adding one finds out here rather than on a public page:
#
#   * every preset is multi-select
#   * option lists stay short — an answer that isn't on the list is a chip the
#     parent types themselves, and anything longer than a chip is the section's
#     one free-text field
#   * every built-in section carries exactly one short_text field
#
# The content assertions below are deliberate too. They landed before the
# feature was announced, when deleting an option destroyed nothing because
# nothing was stored; a later change to any of them has to go through
# DEPRECATED_CARE_OPTIONS instead.
RSpec.describe "the care presets" do
  def fields_for(section_key)
    Profile::CARE_SECTIONS.fetch(section_key)[:fields]
  end

  def field(section_key, field_key)
    fields_for(section_key).find { |f| f[:key] == field_key }
  end

  def every_field
    Profile::CARE_SECTIONS.flat_map do |section_key, spec|
      spec[:fields].map { |f| [section_key, f] }
    end
  end

  describe "the rules every section follows" do
    it "has no single-select field anywhere" do
      # A single-select forces a parent to pick the one truest thing about
      # someone whose support is layered. A half-true chip on a card a
      # substitute reads is worse than no chip.
      offenders = every_field.select { |_, f| f[:type] == :single_select }
                             .map { |section, f| "#{section}.#{f[:key]}" }

      expect(offenders).to be_empty
    end

    it "uses only the three types the sanitizer knows how to clean" do
      types = every_field.map { |_, f| f[:type] }.uniq
      expect(types - %i[multi_select short_text]).to be_empty
    end

    # The one list that outgrows the ceiling, on purpose. Every entry answers a
    # different question for a helper: aac_book matters when the device is
    # dead, eye_gaze and partner_assisted change what they physically do, and
    # sign vs gestures is formal vs informal. Nothing here compresses.
    WIDE_BY_DESIGN = ["communication.methods"].freeze

    it "keeps every option list short enough to scan" do
      # Six is the ceiling, not the target. A longer list is usually a sign the
      # answer wanted to be a detail line; if it genuinely isn't, add it to
      # WIDE_BY_DESIGN above with the reason, so the exception stays visible.
      too_long = every_field.select { |section, f|
        f[:options] && f[:options].length > 6 &&
          WIDE_BY_DESIGN.exclude?("#{section}.#{f[:key]}")
      }.map { |section, f| "#{section}.#{f[:key]} (#{f[:options].length})" }

      expect(too_long).to be_empty
    end

    it "keeps even the exempt lists inside the sanitizer's multi-select cap" do
      every_field.each do |section_key, f|
        next unless f[:options]

        expect(f[:options].length).to be <= Profile::MAX_CARE_MULTI_SELECT,
                                      "#{section_key}.#{f[:key]} offers more than the sanitizer will store"
      end
    end

    it "gives every built-in section exactly one free-text field" do
      # This used to assert the opposite — no `notes` field anywhere — because
      # the per-section detail lines were the free-text surface and two of them
      # side by side just split the same answer across two boxes. The editor
      # stopped offering detail lines when custom chips landed, so a single
      # short_text is now that surface. The "exactly one" half of the rule is
      # the part that carried over unchanged.
      Profile::CARE_SECTIONS.each_key do |section_key|
        short_texts = fields_for(section_key).select { |f| f[:type] == :short_text }

        expect(short_texts.length).to eq(1),
                                      "#{section_key} has #{short_texts.length} free-text fields, expected exactly 1"
      end
    end

    it "has no duplicate field keys inside a section" do
      Profile::CARE_SECTIONS.each_key do |section_key|
        keys = fields_for(section_key).map { |f| f[:key] }
        expect(keys).to eq(keys.uniq), "#{section_key} repeats a field key"
      end
    end

    it "has no duplicate options inside a field" do
      every_field.each do |section_key, f|
        next unless f[:options]

        expect(f[:options]).to eq(f[:options].uniq),
                               "#{section_key}.#{f[:key]} repeats an option"
      end
    end
  end

  describe "sections" do
    it "serves them in the order the editor renders" do
      expect(Profile::CARE_SECTIONS.keys).to eq(
        %w[communication personal_care meals sensory mobility transportation],
      )
    end

    it "gives sensory its own section rather than a corner of meals" do
      # Noise on the bus and lights in a classroom cut across every other
      # section and had nowhere to live.
      expect(fields_for("sensory").map { |f| f[:key] }).to eq(%w[sound touch light calming])
    end

    it "separates mobility from getting around" do
      # A wheelchair or a pair of AFOs is true all day, in every room. It is
      # not a fact about the trip to school.
      expect(fields_for("mobility").map { |f| f[:key] }).to eq(%w[equipment support notes])
      expect(field("mobility", "equipment")[:options]).to include("wheelchair", "braces_or_afos")
    end
  end

  describe "options that were deliberately cut" do
    def options_for(section_key, field_key)
      field(section_key, field_key)&.fetch(:options, nil) || []
    end

    it "no longer offers echolalia as a communication method" do
      expect(options_for("communication", "methods")).not_to include("echolalia")
    end

    it "replaced the help-level scales with concrete supports" do
      expect(field("communication", "help_level")).to be_nil
      expect(field("personal_care", "help_level")).to be_nil
      expect(options_for("communication", "what_helps")).to include("wait_and_pause")
    end

    it "dropped the response-time field" do
      # Knowing someone "needs time" changed nobody's behaviour; "wait and
      # pause" tells a helper what to actually do.
      expect(field("communication", "response_time")).to be_nil
    end

    it "dropped the seat-specific transportation chips" do
      # Both were "which seat", which is a detail line, not a category.
      expect(options_for("transportation", "seating"))
        .not_to include("specific_seat", "front_seat_only")
    end

    it "dropped personal care's redundant `both` schedule option" do
      # Redundant the moment the field went multi-select.
      expect(options_for("personal_care", "schedule")).to eq(%w[on_request scheduled_times])
    end

    it "names the on-foot travel option `walks`, not `walker`" do
      # With a Mobility section next door, `walker` reads as the device.
      travel = options_for("transportation", "school_travel")
      expect(travel).to include("walks")
      expect(travel).not_to include("walker")
    end
  end

  describe "the served registry" do
    it "carries no trace of a cut option" do
      serialized = Profile.care_registry_view.to_json

      %w[echolalia response_time help_level specific_seat front_seat_only]
        .each { |cut| expect(serialized).not_to include(cut) }
    end
  end

  describe "round-tripping through the sanitizer" do
    let(:user) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }
    let(:profile) do
      Profile.create!(profileable: child, username: "preset-spec", slug: "preset-spec")
    end

    it "stores every offered option on every section" do
      # The reshape moved five fields from single- to multi-select. The
      # sanitizer branches on type, so a field left behind would silently drop
      # everything a parent picked for it.
      sections = Profile::CARE_SECTIONS.each_with_object({}) do |(key, spec), acc|
        values = spec[:fields].each_with_object({}) do |f, vals|
          vals[f[:key]] = f[:type] == :short_text ? "a note" : f[:options]
        end
        acc[key] = { "enabled" => true, "values" => values }
      end

      profile.update!(settings: { "care" => { "sections" => sections } })
      stored = profile.reload.settings.dig("care", "sections")

      Profile::CARE_SECTIONS.each do |key, spec|
        spec[:fields].each do |f|
          expected = f[:type] == :short_text ? "a note" : f[:options]
          expect(stored.dig(key, "values", f[:key])).to eq(expected),
                                                        "#{key}.#{f[:key]} was dropped by the sanitizer"
        end
      end
    end
  end
end
