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

    # Section key -> the per-section colour/icon suffix used by the CSS
    # (`.s-comm`, `.s-care`, ...) and by CarePlanIcons. A custom section isn't
    # in this map on purpose: #style_key_for falls back to "trav" (navy) for
    # anything it doesn't recognize, which is what keeps a parent's four custom
    # sections from turning the sheet into a paint chart.
    STYLE_KEYS = {
      "communication" => "comm",
      "personal_care" => "care",
      "meals" => "meal",
      "sensory" => "sens",
      "mobility" => "move",
      "transportation" => "trav",
    }.freeze

    def self.style_key_for(section)
      STYLE_KEYS.fetch(section.key, "trav")
    end

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

    # The "At a glance" strip's allergy cell. Its own reader, separate from
    # #emergency_fields, because it renders in exactly one place on the sheet —
    # the glance strip — never inside the emergency grid. See
    # OMIT_BLANK_EMERGENCY_FIELDS's sibling rule in the template: printing this
    # twice was the first mockup's bug.
    def allergies
      all_emergency_fields.find { |field| field.key == "allergies" }&.values&.first
    end

    # The glance strip's "How I talk" cell — { primary:, sub: }, or nil when
    # nothing is stored (the template falls back to a neutral cell, same as an
    # unanswered allergy field falls back to "None listed").
    #
    # Built from the communication section's stored answers but deliberately
    # independent of `only_sections`: it introduces the person, it isn't part
    # of the printed detail sections, and narrowing the sheet to "meals only"
    # shouldn't erase how the sheet's subject talks. A section the parent
    # explicitly disabled is still respected, though.
    #
    # The identity block's line under the name used to be derived from these
    # same answers ("I communicate using AAC device and gestures…") and is not
    # any more — it is the caller's `subheader` now. See GenerateCarePlan.
    def glance_how_i_talk
      return nil if communication_methods.empty?

      { primary: communication_methods.first, sub: glance_how_i_talk_sub }
    end

    # One "Section label: joined values" line per section, in printed order,
    # capped at `limit`. This is the wallet card's whole day-to-day content —
    # five lines, no chips, no room for anything else — and the truncated tier
    # of the half-page's overflow ladder reaches for the same method. A section
    # with nothing to say (custom section with items only, say) still renders
    # by folding item values in alongside field values.
    #
    # `truncate_at` bounds each LINE's own length, not just the count of lines
    # — a maxed-out section (Profile::MAX_CARE_MULTI_SELECT values, or a
    # custom section's Profile::MAX_CARE_CUSTOM_ITEMS items) joins into one
    # very long string, and even a five-line cap silently overflowed the
    # wallet's 2in half once that string wrapped to several visual lines on
    # its own. Both fixed-height sizes pass it — the half page's back panel is
    # more spacious, not unbounded.
    #
    # It cuts on a WORD boundary. These lines are a comma-joined list of short
    # care options, so a mid-word cut lands inside one of them and prints a
    # fragment ("Keep my device close, Wai…") that reads as a different answer
    # from the one the parent chose — worse than dropping it.
    def condensed_care_lines(limit: nil, truncate_at: nil)
      lines = care_sections.filter_map do |section|
        parts = section.fields.map { |f| f.values.join(", ") } + section.items.map(&:value)
        next if parts.empty?

        text = parts.join(", ")
        text = text.truncate(truncate_at, separator: " ", omission: "…") if truncate_at

        { label: section.label, text: text }
      end

      limit ? lines.first(limit) : lines
    end

    # care_sections, with every multi_select field's values capped at
    # `max_values` — the half-page's middle overflow tier (drop from chips to
    # comma-joined text before dropping content outright). Fields and items
    # untouched when max_values is nil.
    def care_sections(max_values: nil)
      sections = @care_sections ||= ordered_keys.filter_map { |key| build_section(key) }
      return sections unless max_values

      sections.map do |section|
        Section.new(
          key: section.key, label: section.label, custom: section.custom, items: section.items,
          fields: section.fields.map do |field|
            Field.new(key: field.key, label: field.label, type: field.type,
              values: field.values.first(max_values))
          end,
        )
      end
    end

    # A rough, deterministic proxy for "will this overflow a fixed 5.5in
    # panel" — there is no headless Chrome available at spec time to actually
    # paginate against, so the half/wallet overflow ladder is driven by this
    # weighted count instead of a real layout measurement. Calibrated against
    # the two shapes the acceptance criteria name: a sparse profile (a
    # handful of chips per section) should land well under both thresholds,
    # and a maxed-out profile (Profile::MAX_CARE_MULTI_SELECT values in every
    # field, across every section, plus 4 custom sections of 8 items each)
    # should clear both by a wide margin.
    def care_content_weight
      care_sections.sum do |section|
        section.fields.sum do |field|
          field.type == :short_text ? (field.values.first.to_s.length / 40.0) : field.values.length * 3
        end + section.items.length * 4
      end
    end

    HALF_CONDENSE_WEIGHT = 90
    HALF_TRUNCATE_WEIGHT = 160

    # Middle tier: still every section and field, but comma-joined text
    # instead of chips — roughly half the height per row.
    def half_condensed?
      care_content_weight > HALF_CONDENSE_WEIGHT
    end

    # Last tier: even condensed text would overflow the panel, so the template
    # drops to #condensed_care_lines and prints the "Full plan on my live
    # page" note instead of trying to fit everything.
    def half_truncated?
      care_content_weight > HALF_TRUNCATE_WEIGHT
    end

    private

    def communication_fields
      @communication_fields ||= begin
        raw = stored_sections["communication"]
        if raw.is_a?(Hash) && raw["enabled"] != false
          resolve_fields("communication", Profile::CARE_SECTIONS.fetch("communication"), raw["values"])
        else
          []
        end
      end
    end

    def communication_methods
      communication_fields.find { |f| f.key == "methods" }&.values || []
    end

    def glance_how_i_talk_sub
      rest = communication_methods[1..].to_a
      return nil if rest.empty?

      if rest.length == 1
        I18n.t("care.document.glance.plus_one", value: decapitalize(rest.first), locale: locale)
      else
        I18n.t("care.document.glance.plus_many", count: rest.length, locale: locale)
      end
    end

    def decapitalize(str)
      str[0].downcase + str[1..].to_s
    end

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
