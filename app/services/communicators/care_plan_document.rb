# frozen_string_literal: true

module Communicators
  # Turns a Profile into the ordered, labeled blocks the care plan PDF renders.
  #
  # This is a port of `resolveCareSections` in the frontend's
  # src/data/careSections.ts — the PDF renders server-side and the MySpeak care
  # card renders client-side, so the resolution rules genuinely exist twice.
  # That is the class of duplication #673 was written to kill, so: if you change
  # the rules here, change them there, and vice versa. The labels themselves are
  # NOT duplicated (CareLabels serves them), only the walk over stored settings.
  #
  # Rules, all inherited from the frontend:
  #   - stored `order` first, then any section the order forgot, so a stale
  #     order can never drop a section
  #   - `enabled == false` is skipped
  #   - a built-in section survives on values OR detail items alone
  #   - a custom section survives on items alone
  #   - a blank value is omitted rather than rendered empty
  #
  # Kept out of the ERB so it is unit-testable without rendering anything.
  class CarePlanDocument
    Section = Struct.new(:key, :label, :custom, :fields, :items, keyword_init: true)
    Field = Struct.new(:key, :label, :type, :values, keyword_init: true)
    Item = Struct.new(:label, :value, keyword_init: true)

    # The emergency fields, in the order a responder reads them. Contacts are
    # handled separately — they're structured, not free text.
    EMERGENCY_FIELDS = %w[
      allergies
      medical_conditions
      medications
      other_conditions
      emergency_notes
    ].freeze

    # When false, blank emergency fields print as "None listed" on their own row
    # — see the note in .claude-notes/care-plan-pdf-density-handoff.md before
    # flipping this.
    #
    # The trade it makes: a reader in an emergency cannot distinguish "this child
    # has no allergies" from "nobody filled in the allergies field" once the
    # field is absent. #blank_emergency_field_names exists so the template can
    # print one muted line naming what went unanswered, which keeps the honest
    # signal at the cost of a line instead of ten.
    OMIT_BLANK_EMERGENCY_FIELDS = true

    # `only_sections` is an ALLOWLIST of section keys, and nil is not the same
    # thing as an empty array: nil means "every stored section" (what every
    # caller did before the picker existed), while [] means the caller asked for
    # none of them — a real request on the :full variant, where the emergency
    # page alone is the document. `Array(nil)` collapses the two, so the
    # normalization has to guard on nil explicitly.
    def initialize(profile, locale: I18n.locale, only_sections: nil)
      @profile = profile
      @locale = locale
      @only_sections =
        only_sections.nil? ? nil : Array(only_sections).map { |key| key.to_s.strip }.reject(&:empty?)
    end

    attr_reader :profile, :locale, :only_sections

    def care_sections
      @care_sections ||= ordered_keys.filter_map { |key| build_section(key) }
    end

    def care?
      care_sections.any?
    end

    # The emergency fields worth printing. Blank ones are dropped under
    # OMIT_BLANK_EMERGENCY_FIELDS and named collectively by
    # #blank_emergency_field_names instead.
    def emergency_fields
      fields = all_emergency_fields
      return fields unless OMIT_BLANK_EMERGENCY_FIELDS

      fields.select { |field| field.values.any? }
    end

    # Short, lowercase names for the emergency fields nobody answered, in
    # EMERGENCY_FIELDS order — the template joins them into the one muted line
    # that replaces ten "None listed" rows. Empty when nothing is being omitted,
    # so the template needs no second condition.
    def blank_emergency_field_names
      return [] unless OMIT_BLANK_EMERGENCY_FIELDS

      all_emergency_fields.reject { |field| field.values.any? }.map do |field|
        I18n.t("care.document.emergency.blank_names.#{field.key}", locale: locale)
      end
    end

    def emergency_contacts
      profile.safety_contacts
    end

    def emergency?
      profile.has_safety_info?
    end

    private

    def all_emergency_fields
      @all_emergency_fields ||= EMERGENCY_FIELDS.map do |key|
        Field.new(
          key: key,
          label: I18n.t("care.document.emergency.#{key}", locale: locale),
          type: :short_text,
          values: [settings[key].to_s.strip.presence].compact,
        )
      end
    end

    def settings
      @settings ||= profile.settings.is_a?(Hash) ? profile.settings : {}
    end

    def care_settings
      @care_settings ||= profile.care_settings
    end

    def stored_sections
      @stored_sections ||= begin
        raw = care_settings["sections"]
        raw.is_a?(Hash) ? raw : {}
      end
    end

    # Stored order first, then whatever it forgot. A section must never vanish
    # from the printed sheet just because `order` went stale.
    #
    # The allowlist is applied HERE, after the order walk, so a narrowed
    # document still prints in the owner's own order and a filtered-out section
    # is never built. A key in the selection that isn't stored simply doesn't
    # intersect — which is also why the selection needs no validation: it only
    # ever gets to remove keys the profile already had.
    def ordered_keys
      ordered = Array(care_settings["order"]).select do |key|
        key.is_a?(String) && stored_sections.key?(key)
      end

      keys = ordered + (stored_sections.keys - ordered)
      return keys if only_sections.nil?

      keys & only_sections
    end

    def build_section(key)
      raw = stored_sections[key]
      return unless raw.is_a?(Hash)
      return if raw["enabled"] == false

      spec = Profile::CARE_SECTIONS[key]
      spec ? built_in_section(key, spec, raw) : custom_section(key, raw)
    end

    def built_in_section(key, spec, raw)
      fields = resolve_fields(key, spec, raw["values"])
      items = resolve_items(raw)
      return if fields.empty? && items.empty?

      Section.new(
        key: key,
        label: CareLabels.section(key, locale: locale),
        custom: false,
        fields: fields,
        items: items,
      )
    end

    # A parent-authored section. Its key was generated client-side, so the
    # format check is what keeps an arbitrary key from rendering as a heading.
    def custom_section(key, raw)
      return unless key.match?(Profile::CARE_CUSTOM_KEY_FORMAT)

      items = resolve_items(raw)
      return if items.empty?

      Section.new(
        key: key,
        label: raw["title"].to_s.strip.presence ||
               I18n.t("care.document.custom_section", locale: locale),
        custom: true,
        fields: [],
        items: items,
      )
    end

    def resolve_fields(section_key, spec, values)
      raw = values.is_a?(Hash) ? values : {}

      spec[:fields].filter_map do |field|
        resolved = resolve_field(section_key, field, raw[field[:key]])
        resolved if resolved&.values&.any?
      end
    end

    def resolve_field(section_key, field, value)
      resolved =
        if field[:type] == :multi_select
          Array(value).filter_map { |v| v.to_s.strip.presence }
        else
          [value.to_s.strip.presence].compact
        end

      # Select values are option KEYS and get labeled; short_text is already
      # the parent's own words and must be printed verbatim.
      labeled =
        if field[:type] == :short_text
          resolved
        else
          resolved.map { |v| CareLabels.option(section_key, field[:key], v, locale: locale) }
        end

      Field.new(
        key: field[:key],
        label: CareLabels.field(section_key, field[:key], locale: locale),
        type: field[:type],
        values: labeled,
      )
    end

    def resolve_items(raw)
      items = raw["items"]
      return [] unless items.is_a?(Array)

      items.filter_map do |item|
        next unless item.is_a?(Hash)

        label = item["label"].to_s.strip
        value = item["value"].to_s.strip
        next if label.empty? && value.empty?

        Item.new(label: label, value: value)
      end
    end
  end
end
