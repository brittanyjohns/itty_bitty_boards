class PreprocessDocTileVariantJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 2

  def perform(doc_id)
    doc = Doc.includes(image_attachment: :blob).find_by(id: doc_id)
    return unless doc&.image&.attached?
    return unless doc.image.variable?
    return if doc.tile_variant_marked_processed?

    doc.tile_variant.processed
    doc.mark_tile_variant_processed!
  rescue => e
    Rails.logger.error("[tile-variant] failed for Doc #{doc_id}: #{e.message}")
    raise e
  end
end
