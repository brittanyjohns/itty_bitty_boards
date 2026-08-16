class PreprocessDocTileVariantJob
  include Sidekiq::Job
  sidekiq_options queue: :varients, retry: 2

  def perform(doc_id)
    return if AppEnv.staging?

    doc = Doc.includes(image_attachment: :blob).find_by(id: doc_id)
    return unless doc&.image&.attached?

    doc.ensure_tile_variant!
  rescue => e
    Rails.logger.error("[tile-variant] failed for Doc #{doc_id}: #{e.message}")
    raise e
  end
end
