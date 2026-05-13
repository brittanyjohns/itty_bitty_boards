class TranslateBoardImagesJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  # Walks every image on a board and queues a TranslateImageJob for any whose
  # `language_settings` is missing the requested language. Splitting per-image
  # keeps each OpenAI call retryable and bounded.
  def perform(board_id, language)
    board = Board.find_by(id: board_id)
    return unless board

    language = language.to_s
    return if language.blank? || language == "en"
    return unless Image.languages.include?(language)

    board.board_images.includes(:image).find_each do |bi|
      image = bi.image
      next unless image && image.label.present?

      existing = (image.language_settings || {})[language]
      next if existing.is_a?(Hash) && (existing["label"] || existing[:label]).to_s.strip.present?

      TranslateImageJob.perform_async(image.id, language)
    end
  end
end
