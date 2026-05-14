class TranslateImageJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  def perform(image_id, language)
    image = Image.find_by(id: image_id)
    return unless image
    return if image.label.blank?

    language = language.to_s
    return if language.blank? || language == "en"
    return unless Image.languages.include?(language)

    existing = (image.language_settings || {})[language]
    if existing.is_a?(Hash) && (existing["label"] || existing[:label]).to_s.strip.present?
      return
    end

    image.translate_to(language)
    image.save!
  end
end
