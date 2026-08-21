# frozen_string_literal: true

require "rails_helper"

# The presenter is a port of resolveCareSections in the frontend's
# src/data/careSections.ts. These examples pin the rules that port has to keep:
# stored order wins, a stale order can't drop a section, disabled sections are
# skipped, and a section survives on detail lines alone.
RSpec.describe Communicators::CarePlanDocument do
  let(:user) { create(:user) }
  let(:account) { create(:child_account, user: user, owner: user) }
  let(:profile) do
    Profile.create!(profileable: account, username: "doc-#{SecureRandom.hex(2)}",
                    slug: "doc-#{SecureRandom.hex(2)}")
  end

  def with_care(care, extra = {})
    profile.update!(settings: { "care" => care }.merge(extra))
    described_class.new(profile.reload)
  end

  def with_care_only(care, only_sections)
    profile.update!(settings: { "care" => care })
    described_class.new(profile.reload, only_sections: only_sections)
  end

  describe "#care_sections" do
    it "labels the section, its fields, and its option values" do
      doc = with_care(
        "sections" => {
          "communication" => {
            "enabled" => true,
            "values" => { "methods" => %w[aac_device eye_gaze] },
          },
        },
      )

      section = doc.care_sections.first
      expect(section.label).to eq("Communication")
      expect(section.fields.first.label).to eq("How I communicate")
      # The whole point of the label layer: option KEYS never reach paper.
      expect(section.fields.first.values).to eq(["AAC device", "Eye gaze"])
    end

    it "renders short_text verbatim rather than labeling it" do
      doc = with_care(
        "sections" => {
          "meals" => { "values" => { "preferences" => "hates anything cold" } },
        },
      )

      field = doc.care_sections.first.fields.first
      expect(field.type).to eq(:short_text)
      expect(field.values).to eq(["hates anything cold"])
    end

    # Care text reaches the presenter unescaped — the template escapes on
    # output, so anything already escaped here prints as a visible entity.
    it "carries a typed ampersand through as a plain character" do
      doc = with_care(
        "sections" => {
          "sensory" => { "values" => { "calming" => "Loves hugs & quiet spaces" } },
        },
      )

      expect(doc.care_sections.first.fields.first.values)
        .to eq(["Loves hugs & quiet spaces"])
    end

    it "follows the stored order" do
      doc = with_care(
        "order" => %w[mobility communication],
        "sections" => {
          "communication" => { "values" => { "methods" => ["sign"] } },
          "mobility" => { "values" => { "equipment" => ["wheelchair"] } },
        },
      )

      expect(doc.care_sections.map(&:key)).to eq(%w[mobility communication])
    end

    # A section must never vanish from a printed plan because `order` went
    # stale — same rule as the frontend.
    it "appends sections the stored order forgot" do
      doc = with_care(
        "order" => %w[mobility],
        "sections" => {
          "communication" => { "values" => { "methods" => ["sign"] } },
          "mobility" => { "values" => { "equipment" => ["wheelchair"] } },
        },
      )

      expect(doc.care_sections.map(&:key)).to eq(%w[mobility communication])
    end

    it "ignores an order entry for a section that is not stored" do
      doc = with_care(
        "order" => %w[sensory mobility],
        "sections" => { "mobility" => { "values" => { "equipment" => ["wheelchair"] } } },
      )

      expect(doc.care_sections.map(&:key)).to eq(%w[mobility])
    end

    it "skips a section the parent turned off" do
      doc = with_care(
        "sections" => {
          "communication" => { "enabled" => false, "values" => { "methods" => ["sign"] } },
          "mobility" => { "values" => { "equipment" => ["wheelchair"] } },
        },
      )

      expect(doc.care_sections.map(&:key)).to eq(%w[mobility])
    end

    it "omits a section with neither values nor detail lines" do
      doc = with_care("sections" => { "communication" => { "enabled" => true, "values" => {} } })

      expect(doc.care_sections).to be_empty
    end

    it "keeps a built-in section that has only detail lines" do
      doc = with_care(
        "sections" => {
          "meals" => {
            "values" => {},
            "items" => [{ "label" => "Drinks", "value" => "watered-down apple juice" }],
          },
        },
      )

      section = doc.care_sections.first
      expect(section.fields).to be_empty
      expect(section.items.map(&:value)).to eq(["watered-down apple juice"])
    end

    it "drops a detail line with neither a label nor a value" do
      doc = with_care(
        "sections" => {
          "meals" => {
            "values" => { "textures" => ["soft"] },
            "items" => [{ "label" => "", "value" => "" }, { "label" => "Cup", "value" => "" }],
          },
        },
      )

      expect(doc.care_sections.first.items.map(&:label)).to eq(["Cup"])
    end

    it "omits a field the parent left blank" do
      doc = with_care(
        "sections" => {
          "meals" => { "values" => { "textures" => ["soft"], "preferences" => "  " } },
        },
      )

      expect(doc.care_sections.first.fields.map(&:key)).to eq(%w[textures])
    end

    describe "custom sections" do
      it "renders a parent-authored section under its own title" do
        doc = with_care(
          "sections" => {
            "c_7f3a91" => {
              "custom" => true,
              "title" => "Bedtime",
              "items" => [{ "label" => "Lights", "value" => "off by 7" }],
            },
          },
        )

        section = doc.care_sections.first
        expect(section.custom).to be(true)
        expect(section.label).to eq("Bedtime")
      end

      # clean_custom_care_section refuses a blank title, so this cannot arrive
      # through a normal save — it takes an update_columns (a rake task, a
      # console fix) to skip the callback. The fallback is a backstop for
      # exactly that, and the frontend's resolveCustom is equally tolerant, so
      # a heading is never blank on either surface.
      it "falls back to generic copy for a titleless section written past the sanitizer" do
        profile.update_columns(
          settings: { "care" => {
            "sections" => { "c_7f3a91" => { "items" => [{ "label" => "x", "value" => "y" }] } },
          } },
        )

        expect(described_class.new(profile.reload).care_sections.first.label)
          .to eq("More about me")
      end

      it "cannot store a titleless custom section through a normal save" do
        doc = with_care(
          "sections" => { "c_7f3a91" => { "items" => [{ "label" => "x", "value" => "y" }] } },
        )

        expect(doc.care_sections).to be_empty
      end

      # The key is generated client-side, so the format check is the only thing
      # keeping an arbitrary key from rendering as a heading on a printed sheet.
      it "refuses a section key that is neither built-in nor a valid custom key" do
        doc = with_care(
          "sections" => { "../../etc" => { "items" => [{ "label" => "x", "value" => "y" }] } },
        )

        expect(doc.care_sections).to be_empty
      end
    end

    describe "malformed stored data" do
      it "returns nothing when care is absent" do
        profile.update!(settings: {})
        expect(described_class.new(profile.reload).care_sections).to be_empty
      end

      it "survives sections stored as something other than a hash" do
        expect(with_care("sections" => "nope").care_sections).to be_empty
        expect(with_care("sections" => { "meals" => "nope" }).care_sections).to be_empty
      end
    end
  end

  describe "emergency data" do
    let(:emergency) do
      {
        "allergies" => "peanuts",
        "medications" => "melatonin",
        "ice_contact_1" => { "name" => "Sam", "phone" => "555-0100", "relationship" => "Dad" },
      }
    end

    # Blank fields cost a row each and print nothing but "None listed", which is
    # what pushed a near-empty profile onto two pages.
    it "exposes only the emergency fields that were answered" do
      doc = with_care({ "sections" => {} }, emergency)

      fields = doc.emergency_fields.index_by(&:key)
      expect(fields.keys).to eq(%w[allergies medications])
      expect(fields["allergies"].values).to eq(["peanuts"])
    end

    # The omitted fields are still accounted for — one muted line naming them
    # keeps "nobody answered this" distinguishable from "there is nothing here".
    it "names the blank emergency fields, in reading order" do
      doc = with_care({ "sections" => {} }, emergency)

      expect(doc.blank_emergency_field_names)
        .to eq(["conditions", "other conditions", "notes"])
    end

    it "names nothing when every field is answered" do
      answered = described_class::EMERGENCY_FIELDS.index_with { "something" }
      doc = with_care({ "sections" => {} }, answered)

      expect(doc.emergency_fields.length).to eq(described_class::EMERGENCY_FIELDS.length)
      expect(doc.blank_emergency_field_names).to be_empty
    end

    # The flag is the documented one-line revert. If it is ever flipped back,
    # every field returns and nothing is summarised.
    it "keeps every field and names none when OMIT_BLANK_EMERGENCY_FIELDS is off" do
      stub_const("#{described_class}::OMIT_BLANK_EMERGENCY_FIELDS", false)
      doc = with_care({ "sections" => {} }, emergency)

      expect(doc.emergency_fields.map(&:key)).to eq(described_class::EMERGENCY_FIELDS)
      expect(doc.blank_emergency_field_names).to be_empty
    end

    it "exposes contacts through Profile#safety_contacts" do
      doc = with_care({ "sections" => {} }, emergency)

      expect(doc.emergency_contacts.map { |c| c["name"] }).to eq(["Sam"])
    end

    it "reports whether there is any emergency info at all" do
      expect(with_care({ "sections" => {} }, emergency).emergency?).to be(true)
      expect(with_care("sections" => {}).emergency?).to be(false)
    end
  end

  # The section picker's server half. The selection is an ALLOWLIST, applied
  # after the order walk, and nil is not [] — see the note on #initialize.
  describe "only_sections" do
    let(:three_sections) do
      {
        "order" => %w[meals sensory communication],
        "sections" => {
          "communication" => { "values" => { "methods" => ["aac_device"] } },
          "meals" => { "values" => { "preferences" => "hates anything cold" } },
          "sensory" => { "values" => { "calming" => "quiet spaces" } },
        },
      }
    end

    it "prints every stored section when nil" do
      doc = with_care_only(three_sections, nil)

      expect(doc.care_sections.map(&:key)).to eq(%w[meals sensory communication])
    end

    it "prints only the selected sections, still in the owner's order" do
      # Passed in a different order than stored, to pin that the SELECTION does
      # not reorder the sheet.
      doc = with_care_only(three_sections, %w[communication meals])

      expect(doc.care_sections.map(&:key)).to eq(%w[meals communication])
    end

    it "ignores a key the profile has no section for" do
      doc = with_care_only(three_sections, %w[meals not_a_section])

      expect(doc.care_sections.map(&:key)).to eq(%w[meals])
    end

    # [] is a real request on the :full variant — the emergency page alone.
    # This is why the argument can't be normalized with Array().
    it "prints no sections when given an empty selection" do
      doc = with_care_only(three_sections, [])

      expect(doc.care_sections).to be_empty
      expect(doc.care?).to be(false)
    end

    it "answers #care? about the selected sections only" do
      expect(with_care_only(three_sections, %w[meals]).care?).to be(true)
      expect(with_care_only(three_sections, %w[transportation]).care?).to be(false)
    end

    it "tolerates blanks and symbols in the selection" do
      doc = with_care_only(three_sections, [:meals, "", "  sensory  ", nil])

      expect(doc.care_sections.map(&:key)).to eq(%w[meals sensory])
    end
  end

  describe ".style_key_for" do
    it "maps every built-in section to its own colour key" do
      %w[communication personal_care meals sensory mobility transportation].each do |key|
        section = described_class::Section.new(key: key, label: key, custom: false, fields: [], items: [])
        expect(described_class.style_key_for(section)).to eq(
          { "communication" => "comm", "personal_care" => "care", "meals" => "meal",
            "sensory" => "sens", "mobility" => "move", "transportation" => "trav" }.fetch(key),
        )
      end
    end

    # A custom section shares the navy colour rather than inventing its own —
    # a parent can add four and the sheet would turn into a paint chart.
    it "maps a custom section to the transportation colour" do
      section = described_class::Section.new(key: "c_7f3a91", label: "Bedtime", custom: true, fields: [], items: [])
      expect(described_class.style_key_for(section)).to eq("trav")
    end
  end

  # The identity block's first-person line and the glance strip's "How I
  # talk" cell — both derived from the communication section, independent of
  # `only_sections`.
  describe "#says and #glance_how_i_talk" do
    it "is nil when nothing is stored for communication" do
      doc = with_care("sections" => { "meals" => { "values" => { "preferences" => "hates cold food" } } })

      expect(doc.says).to be_nil
      expect(doc.glance_how_i_talk).to be_nil
    end

    it "carries the primary method, the rest, and what helps" do
      doc = with_care(
        "sections" => {
          "communication" => {
            "values" => { "methods" => %w[aac_device eye_gaze some_speech], "what_helps" => ["wait_and_pause"] },
          },
        },
      )

      says = doc.says
      expect(says.primary).to eq("AAC device")
      # Sentence-cased for the middle of a sentence, not the label's own casing.
      expect(says.rest).to eq(["eye gaze", "some speech"])
      expect(says.helps).to eq("Wait and pause")
    end

    it "builds the glance cell's primary value and a 'plus N more' sub line" do
      doc = with_care(
        "sections" => { "communication" => { "values" => { "methods" => %w[aac_device eye_gaze some_speech] } } },
      )

      glance = doc.glance_how_i_talk
      expect(glance[:primary]).to eq("AAC device")
      expect(glance[:sub]).to eq("plus 2 more")
    end

    it "says 'plus <value>' rather than 'plus 1 more' for exactly one extra method" do
      doc = with_care("sections" => { "communication" => { "values" => { "methods" => %w[aac_device eye_gaze] } } })

      expect(doc.glance_how_i_talk[:sub]).to eq("plus eye gaze")
    end

    it "respects a communication section the parent disabled" do
      doc = with_care(
        "sections" => { "communication" => { "enabled" => false, "values" => { "methods" => ["aac_device"] } } },
      )

      expect(doc.says).to be_nil
    end

    it "is independent of only_sections — narrowing to another section keeps it" do
      doc = with_care_only(
        {
          "sections" => {
            "communication" => { "values" => { "methods" => ["aac_device"] } },
            "meals" => { "values" => { "preferences" => "hates cold food" } },
          },
        },
        %w[meals],
      )

      expect(doc.care_sections.map(&:key)).to eq(%w[meals])
      expect(doc.says.primary).to eq("AAC device")
    end
  end

  describe "#allergies and #call_first_contact" do
    it "resolves allergies from the emergency data" do
      doc = with_care({ "sections" => {} }, { "allergies" => "peanuts" })
      expect(doc.allergies).to eq("peanuts")
    end

    it "is nil when allergies were never answered" do
      doc = with_care({ "sections" => {} }, {})
      expect(doc.allergies).to be_nil
    end

    it "is the first stored emergency contact" do
      doc = with_care(
        { "sections" => {} },
        {
          "ice_contact_1" => { "name" => "Sam", "phone" => "555-0100", "relationship" => "Dad" },
          "ice_contact_2" => { "name" => "Alex", "phone" => "555-0200", "relationship" => "Mom" },
        },
      )

      expect(doc.call_first_contact["name"]).to eq("Sam")
    end

    it "is nil when there are no contacts" do
      doc = with_care({ "sections" => {} }, {})
      expect(doc.call_first_contact).to be_nil
    end
  end

  describe "#condensed_care_lines" do
    it "joins each section's field and item values into one line" do
      doc = with_care(
        "order" => %w[meals],
        "sections" => {
          "meals" => {
            "values" => { "textures" => %w[soft chopped] },
            "items" => [{ "label" => "Drinks", "value" => "watered-down apple juice" }],
          },
        },
      )

      lines = doc.condensed_care_lines
      expect(lines.length).to eq(1)
      expect(lines.first[:label]).to eq("Meals & snacks")
      expect(lines.first[:text]).to eq("Soft, Chopped, watered-down apple juice")
    end

    it "caps the number of lines when a limit is given" do
      doc = with_care(
        "order" => %w[communication meals sensory],
        "sections" => {
          "communication" => { "values" => { "methods" => ["aac_device"] } },
          "meals" => { "values" => { "preferences" => "hates cold food" } },
          "sensory" => { "values" => { "calming" => "quiet spaces" } },
        },
      )

      expect(doc.condensed_care_lines(limit: 2).length).to eq(2)
    end
  end

  describe "#care_sections(max_values:)" do
    it "caps each multi_select field's values without touching short_text or items" do
      doc = with_care(
        "sections" => {
          "meals" => {
            "values" => { "textures" => %w[regular soft chopped pureed thickened_liquids], "preferences" => "loves soup" },
            "items" => [{ "label" => "Drinks", "value" => "juice" }],
          },
        },
      )

      capped = doc.care_sections(max_values: 2).first
      textures = capped.fields.find { |f| f.key == "textures" }
      preferences = capped.fields.find { |f| f.key == "preferences" }

      expect(textures.values.length).to eq(2)
      expect(preferences.values).to eq(["loves soup"])
      expect(capped.items.map(&:value)).to eq(["juice"])
    end

    it "returns the same sections uncapped when max_values is nil" do
      doc = with_care("sections" => { "meals" => { "values" => { "textures" => %w[soft chopped] } } })

      expect(doc.care_sections(max_values: nil).first.fields.first.values.length).to eq(2)
    end
  end

  # A rough, deterministic proxy for "will this overflow a fixed half-page
  # panel" — calibrated so a sparse profile lands under both thresholds and a
  # maxed-out one clears both by a wide margin. See the method's own comment
  # for why this exists instead of a real layout measurement.
  describe "#half_condensed? and #half_truncated?" do
    it "is false for a sparse profile" do
      doc = with_care(
        "order" => %w[communication meals],
        "sections" => {
          "communication" => {
            "values" => { "methods" => %w[aac_device eye_gaze], "what_helps" => ["wait_and_pause"] },
          },
          "meals" => {
            "values" => { "textures" => ["thickened_liquids"], "preferences" => "hates cold food" },
            "items" => [{ "label" => "Drinks", "value" => "watered-down apple juice" }],
          },
        },
      )

      expect(doc.half_condensed?).to be(false)
      expect(doc.half_truncated?).to be(false)
    end

    it "is true for a profile with every documented care limit maxed out" do
      built_in = Profile::CARE_SECTIONS.each_with_object({}) do |(key, spec), acc|
        values = spec[:fields].each_with_object({}) do |field, values_acc|
          values_acc[field[:key]] =
            if field[:type] == :multi_select
              Array.new(Profile::MAX_CARE_MULTI_SELECT) { |i| "opt_#{i}" }
            else
              "x" * Profile::CARE_SHORT_TEXT_MAX
            end
        end
        acc[key] = { "enabled" => true, "values" => values }
      end

      custom = (0...Profile::MAX_CUSTOM_CARE_SECTIONS).each_with_object({}) do |i, acc|
        acc[format("c_%06x", i)] = {
          "custom" => true,
          "title" => "Custom #{i}",
          "items" => Array.new(Profile::MAX_CARE_CUSTOM_ITEMS) { |j| { "label" => "Item #{j}", "value" => "v" * 60 } },
        }
      end

      sections = built_in.merge(custom)
      # Written past the sanitizer (see the titleless-custom-section spec
      # above) — synthetic option keys like "opt_0" aren't accepted options,
      # so a normal save would strip them before CarePlanDocument ever saw them.
      profile.update_columns(settings: { "care" => { "order" => sections.keys, "sections" => sections } })

      doc = described_class.new(profile.reload)
      expect(doc.half_condensed?).to be(true)
      expect(doc.half_truncated?).to be(true)
    end
  end
end
