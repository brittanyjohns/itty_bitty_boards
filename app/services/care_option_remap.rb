# Moving stored care answers off options that have been retired.
#
# Lives here rather than in lib/tasks/care.rake so it autoloads and unit-tests
# like anything else — the rake tasks are a thin shell over it. See
# Profile::DEPRECATED_CARE_OPTIONS for why retirement is a two-step process.
module CareOptionRemap
  module_function

  # Human-readable "section.field.option" labels for every retired option a
  # profile still holds.
  def hits_for(profile)
    care = profile.settings.is_a?(Hash) ? profile.settings["care"] : nil
    sections = care.is_a?(Hash) ? care["sections"] : nil
    return [] unless sections.is_a?(Hash)

    hits = []
    Profile::DEPRECATED_CARE_OPTIONS.each do |section_key, fields|
      values = sections.dig(section_key, "values")
      next unless values.is_a?(Hash)

      fields.each do |field_key, mapping|
        held = Array(values[field_key])
        mapping.each_key do |retired|
          hits << "#{section_key}.#{field_key}.#{retired}" if held.include?(retired)
        end
      end
    end
    hits
  end

  # Returns a rewritten care blob, or nil when nothing changed. A retired option
  # with a nil replacement is dropped; one whose replacement is already present
  # collapses rather than duplicating.
  def apply(care)
    sections = care["sections"]
    return nil unless sections.is_a?(Hash)

    out = Marshal.load(Marshal.dump(care))
    touched = false

    Profile::DEPRECATED_CARE_OPTIONS.each do |section_key, fields|
      values = out.dig("sections", section_key, "values")
      next unless values.is_a?(Hash)

      fields.each do |field_key, mapping|
        current = values[field_key]

        if current.is_a?(Array)
          next unless current.any? { |v| mapping.key?(v) }

          values[field_key] = current
                              .map { |v| mapping.key?(v) ? mapping[v] : v }
                              .compact.uniq
          values.delete(field_key) if values[field_key].empty?
          touched = true
        elsif mapping.key?(current)
          replacement = mapping[current]
          replacement ? values[field_key] = replacement : values.delete(field_key)
          touched = true
        end
      end
    end

    touched ? out : nil
  end
end
