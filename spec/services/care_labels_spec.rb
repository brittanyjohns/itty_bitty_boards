# frozen_string_literal: true

require "rails_helper"

# The care schema is served, so a CARE_SECTIONS edit reaches the editor without
# a frontend deploy — but a label is not derived from a key, so the same edit
# can silently ship an option that renders as "Braces or afos". This file is the
# guard: every key the schema can produce must resolve to a real label, in every
# locale, or the build fails naming the missing path.
RSpec.describe CareLabels do
  # The locales care labels are actually shipped in. I18n.available_locales
  # lists twelve; the other ten have no care strings and legitimately fall back
  # to English, so sweeping all of them would demand translations we aren't
  # writing. Add a locale here when its care.<locale>.yml lands.
  CARE_LOCALES = %i[en es].freeze

  # Reads the raw translation store rather than I18n.exists? / I18n.t, both of
  # which follow config.i18n.fallbacks. `I18n.exists?("care.sections.mobility",
  # :fr)` is TRUE purely because :fr falls back to :en — so a fallback-aware
  # check reports every locale as complete and this whole file becomes a test
  # that English exists. Verified: with the store read below, :fr reports the
  # key missing and :es reports it present.
  def stored_label(path, locale)
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?

    I18n.backend.translations[locale]&.dig(*path.split(".").map(&:to_sym))
  end

  def missing_keys_for(locale)
    missing = []

    Profile::CARE_SECTIONS.each do |section_key, spec|
      section_path = "care.sections.#{section_key}"
      missing << section_path if stored_label(section_path, locale).blank?

      spec[:fields].each do |field|
        field_path = "care.fields.#{section_key}.#{field[:key]}"
        missing << field_path if stored_label(field_path, locale).blank?

        # ACCEPTED, not offered: a retired option has left the registry but is
        # still stored on real profiles and still has to render.
        Profile.accepted_care_options(section_key, field).each do |option_key|
          option_path = "care.options.#{section_key}.#{field[:key]}.#{option_key}"
          missing << option_path if stored_label(option_path, locale).blank?
        end
      end
    end

    missing
  end

  CARE_LOCALES.each do |locale|
    it "labels every section, field, and accepted option in :#{locale}" do
      missing = missing_keys_for(locale)

      expect(missing).to be_empty,
                         "Missing care labels in :#{locale} —\n  #{missing.join("\n  ")}"
    end
  end

  # Proves the sweep above is not vacuous. A locale we ship no care labels for
  # must report them missing; if this ever goes green, the checker has started
  # following fallbacks again and every other example here is worthless.
  it "reports care labels as missing for a locale that has none" do
    expect(missing_keys_for(:fr)).not_to be_empty
  end

  # The reverse sweep. A label left behind after a section or field is deleted
  # is dead weight that reads as though the schema still has it.
  it "has no label for a section that no longer exists" do
    labeled = I18n.t("care.sections", locale: :en).keys.map(&:to_s)

    expect(labeled - Profile::CARE_SECTIONS.keys).to be_empty
  end

  it "has no label for a field that no longer exists" do
    orphans = I18n.t("care.fields", locale: :en).flat_map do |section_key, fields|
      live = Profile::CARE_SECTIONS.dig(section_key.to_s, :fields)&.map { |f| f[:key] } || []
      (fields.keys.map(&:to_s) - live).map { |f| "#{section_key}.#{f}" }
    end

    expect(orphans).to be_empty
  end

  describe "the retirement path" do
    # DEPRECATED_CARE_OPTIONS is empty today (per #678, nothing was stranded by
    # the preset reshape because no profile held care data yet). Stub it so the
    # mechanism is tested rather than today's empty constant — the first real
    # retirement must not be the first time this code path runs.
    it "keeps labeling an option after it is retired out of the registry" do
      field = Profile::CARE_SECTIONS.dig("meals", :fields).find { |f| f[:key] == "textures" }

      stub_const("Profile::DEPRECATED_CARE_OPTIONS",
                 { "meals" => { "textures" => { "minced" => nil } } })

      expect(Profile.offered_care_options("meals", field)).not_to include("minced")
      expect(Profile.accepted_care_options("meals", field)).to include("minced")
      expect(described_class.options_map("meals", field)).to include("minced" => "Minced")
    end
  end

  describe ".humanize" do
    # Transliterated from the frontend's humanize() in CareModal.tsx rather
    # than delegating to String#humanize, which strips a trailing _id and
    # consults inflections. The two sides must agree on exactly the keys
    # nobody has labeled — the only time either fallback runs.
    it "upcases the first letter and replaces underscores" do
      expect(described_class.humanize("keep_my_device_close")).to eq("Keep my device close")
    end

    it "does not strip a trailing _id the way String#humanize does" do
      expect(described_class.humanize("parent_id")).to eq("Parent id")
      expect("parent_id".humanize).to eq("Parent")
    end

    it "handles a blank key without raising" do
      expect(described_class.humanize("")).to eq("")
      expect(described_class.humanize(nil)).to eq("")
    end
  end

  describe "resolution" do
    it "resolves a section, field, and option to their labels" do
      expect(described_class.section("mobility")).to eq("Moving around")
      expect(described_class.field("communication", "what_helps")).to eq("What helps me")
      expect(described_class.option("meals", "textures", "thickened_liquids"))
        .to eq("Thickened liquids")
    end

    # `equipment` exists on both meals and mobility with entirely different
    # options. Keying an option label on anything less than section + field
    # would cross them.
    it "scopes an option label to its section and field" do
      expect(described_class.option("meals", "equipment", "specific_cup")).to eq("Specific cup")
      expect(described_class.option("mobility", "equipment", "wheelchair")).to eq("Wheelchair")
    end

    it "falls back to a humanized key rather than blanking an unlabeled option" do
      expect(described_class.option("meals", "textures", "extra_crunchy")).to eq("Extra crunchy")
    end

    it "resolves in Spanish where a translation exists" do
      expect(described_class.option("sensory", "sound", "likes_music", locale: :es))
        .to eq("Le gusta la música")
    end
  end
end
