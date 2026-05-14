class NormalizeUserVoiceLanguage < ActiveRecord::Migration[7.1]
  LEGACY_NAME_TO_BCP47 = {
    "english" => "en-US",
    "spanish" => "es-US",
    "french" => "fr-FR",
    "german" => "de-DE",
    "italian" => "it-IT",
    "japanese" => "ja-JP",
    "korean" => "ko-KR",
    "dutch" => "nl-NL",
    "polish" => "pl-PL",
    "portuguese" => "pt-PT",
    "russian" => "ru-RU",
    "chinese" => "zh-CN",
  }.freeze

  def up
    User.unscoped.find_each do |user|
      voice = user.settings.is_a?(Hash) ? user.settings["voice"] : nil
      next unless voice.is_a?(Hash)

      raw = voice["language"].to_s.strip
      next if raw.empty?

      normalized = LEGACY_NAME_TO_BCP47[raw.downcase]
      next unless normalized

      voice["language"] = normalized
      user.update_column(:settings, user.settings)
    end
  end

  def down
    # No-op: the legacy values were broken data, not worth restoring.
  end
end
