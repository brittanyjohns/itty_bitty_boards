# frozen_string_literal: true

# Resolves Profile::CARE_SECTIONS keys to human-readable text.
#
# The schema (Profile::CARE_SECTIONS) stores only keys — `what_helps`,
# `thickened_liquids`. This is the single place those become words, for both
# the served registry (Profile.care_registry_view) and anything that renders
# care data server-side. Strings live in config/locales/care.{en,es}.yml.
#
# Mirrors the resolution in the frontend's CareModal.tsx, deliberately:
# `sections.<key>`, `fields.<section>.<field>`, `options.<section>.<field>.<option>`,
# each falling back to a humanized key. Same key shape, same fallback, so the
# printed sheet and the on-screen card can't disagree.
module CareLabels
  class << self
    def section(key, locale: I18n.locale)
      translate("care.sections.#{key}", key, locale)
    end

    def field(section_key, field_key, locale: I18n.locale)
      translate("care.fields.#{section_key}.#{field_key}", field_key, locale)
    end

    # An option key is only unique per section AND field — `meals.equipment`
    # and `mobility.equipment` are different fields with entirely different
    # option sets. Never key an option label on the option alone.
    def option(section_key, field_key, option_key, locale: I18n.locale)
      translate(
        "care.options.#{section_key}.#{field_key}.#{option_key}",
        option_key,
        locale,
      )
    end

    # Every ACCEPTED option for a field, labeled — offered plus anything
    # retired into DEPRECATED_CARE_OPTIONS. A retired option is no longer
    # offered as a fresh choice but is still stored on real profiles and still
    # has to render, so the label map is wider than the option list.
    def options_map(section_key, field, locale: I18n.locale)
      Profile.accepted_care_options(section_key, field).index_with do |option_key|
        option(section_key, field[:key], option_key, locale: locale)
      end
    end

    # Deliberately NOT String#humanize: that strips a trailing `_id` and
    # consults ActiveSupport inflections, so Ruby and TypeScript could disagree
    # on exactly the keys nobody has labeled yet — which is the only time the
    # fallback runs. This is a transliteration of the frontend's humanize().
    def humanize(key)
      spaced = key.to_s.tr("_", " ").strip
      return spaced if spaced.empty?

      spaced[0].upcase + spaced[1..]
    end

    private

    # `default:` rather than a rescue so a missing key is a fallback, not an
    # exception — an unlabeled option must still render as something true
    # rather than blanking the row it sits in.
    def translate(path, fallback_key, locale)
      I18n.t(path, locale: locale, default: humanize(fallback_key))
    end
  end
end
