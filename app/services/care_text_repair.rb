# frozen_string_literal: true

# Repairing care values that were stored HTML-escaped.
#
# The cleaner used to run its text through strip_tags alone, which escapes
# entities on output, so every ampersand a parent typed was persisted as
# "&amp;" and rendered as that literal text on the public MySpeak page and in
# the printed care plan. CareText fixes new writes; this fixes the rows that
# were already saved, which would otherwise stay wrong until their owner
# happened to edit that section again.
#
# Lives here rather than in lib/tasks/care.rake so it autoloads and unit-tests
# like anything else — the rake tasks are a thin shell over it, same as
# CareOptionRemap.
module CareTextRepair
  module_function

  # Every free-text surface, re-cleaned through CareText. Deliberately reuses
  # the model's rule rather than a bare CGI.unescapeHTML: a legacy row can hold
  # an escaped tag ("&lt;script&gt;"), and unescaping that without stripping
  # would write live markup back into the column.
  #
  # Returns a rewritten care blob, or nil when nothing changed — so a caller
  # can skip the write, and so a re-run reports zero.
  def apply(care)
    sections = care["sections"]
    return nil unless sections.is_a?(Hash)

    out = care.deep_dup
    touched = false

    out["sections"].each do |section_key, section|
      next unless section.is_a?(Hash)

      spec = Profile::CARE_SECTIONS[section_key]

      if spec
        # Only short_text fields.
        #
        # A multi_select array is mostly registry KEYS, and running this task's
        # caps over a key is not something it has any business doing. It can
        # also hold a custom chip, which IS prose — but custom chips were added
        # after CareText fixed the escaping, and every one of them was written
        # through it, so no stored chip can be escaped and there is nothing here
        # to repair. If that ever stops being true, walk the array and re-clean
        # only the CARE_CUSTOM_OPTION_PREFIX entries, at CARE_CUSTOM_OPTION_MAX
        # — never the whole array at the short_text cap.
        values = section["values"]
        if values.is_a?(Hash)
          spec[:fields].each do |field|
            next unless field[:type] == :short_text

            touched |= rewrite(values, field[:key], Profile::CARE_SHORT_TEXT_MAX)
          end
        end
      else
        touched |= rewrite(section, "title", Profile::CARE_TITLE_MAX)
      end

      items = section["items"]
      next unless items.is_a?(Array)

      items.each do |item|
        next unless item.is_a?(Hash)

        touched |= rewrite(item, "label", Profile::CARE_ITEM_LABEL_MAX)
        touched |= rewrite(item, "value", Profile::CARE_ITEM_VALUE_MAX)
      end
    end

    touched ? out : nil
  end

  # "section.field" paths whose stored text changes under a repair — what the
  # audit task reports, so a dry run says which fields it would touch.
  def hits_for(profile)
    care = profile.settings.is_a?(Hash) ? profile.settings["care"] : nil
    return [] unless care.is_a?(Hash)

    repaired = apply(care)
    return [] unless repaired

    diff_paths(care["sections"], repaired["sections"])
  end

  # Rewrites in place when the cleaned text differs. A key the blob doesn't
  # hold is left absent rather than written as nil, and a value that cleans to
  # nothing keeps whatever the section already stored — dropping a row is
  # sanitize_care_settings' job, not this task's.
  def rewrite(hash, key, limit)
    return false unless hash.key?(key)

    current = hash[key]
    return false unless current.is_a?(String)

    cleaned = CareText.clean(current, limit).to_s
    return false if cleaned == current || cleaned.blank?

    hash[key] = cleaned
    true
  end

  def diff_paths(before, after)
    return [] unless before.is_a?(Hash) && after.is_a?(Hash)

    paths = []
    after.each do |section_key, section|
      was = before[section_key]
      next unless was.is_a?(Hash) && section.is_a?(Hash)

      paths << "#{section_key}.title" if section["title"] != was["title"]

      (section["values"] || {}).each do |field_key, value|
        paths << "#{section_key}.#{field_key}" if value != was.dig("values", field_key)
      end

      Array(section["items"]).each_with_index do |item, i|
        paths << "#{section_key}.items[#{i}]" if item != Array(was["items"])[i]
      end
    end
    paths
  end
end
