module LocaleResolution
  extend ActiveSupport::Concern

  LEGACY_LANGUAGE_NAME_TO_CODE = {
    "english" => "en",
    "spanish" => "es",
    "french" => "fr",
    "german" => "de",
    "italian" => "it",
    "japanese" => "ja",
    "korean" => "ko",
    "dutch" => "nl",
    "polish" => "pl",
    "portuguese" => "pt",
    "russian" => "ru",
    "chinese" => "zh",
  }.freeze

  # Canonical ISO 639-1 symbol for content lookups (image labels, mailer locale).
  # `language` stays BCP-47 ("en-US") for TTS providers; this is its normalized cousin.
  def i18n_locale
    raw = voice_settings["language"].to_s.strip
    return :en if raw.empty?

    code = LEGACY_LANGUAGE_NAME_TO_CODE[raw.downcase] || raw.split(/[-_]/).first&.downcase
    return :en if code.blank?

    Image.languages.include?(code) ? code.to_sym : :en
  end
end
