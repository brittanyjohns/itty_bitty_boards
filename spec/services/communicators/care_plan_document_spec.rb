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
end
