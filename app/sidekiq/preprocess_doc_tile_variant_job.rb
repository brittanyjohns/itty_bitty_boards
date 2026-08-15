class PreprocessDocTileVariantJob
  include Sidekiq::Job
  sidekiq_options queue: :varients, retry: 2

  def perform(doc_id)
    return if AppEnv.staging?

    doc = Doc.includes(image_attachment: :blob).find_by(id: doc_id)
    return unless doc&.image&.attached?
    return unless doc.ensure_tile_variant!

    repoint_original_urls!(doc)
  rescue => e
    Rails.logger.error("[tile-variant] failed for Doc #{doc_id}: #{e.message}")
    raise e
  end

  private

  # A caller that had to defer this render served the full-resolution original
  # and stored it — Doc#tile_url falls back to display_url rather than render a
  # variant inside a transaction. Now that the 288px rendition exists, move
  # exactly the rows holding THIS doc's original onto it: same picture, a
  # fraction of the bytes on an iPad. Nothing that points anywhere else is
  # touched, and a blank display_image_url ("this tile has no picture") can't
  # match an original url, so the marker survives.
  def repoint_original_urls!(doc)
    image = doc.documentable
    return unless image.is_a?(Image)

    original = doc.display_url
    tile = doc.tile_url
    return if original.blank? || tile.blank? || tile == original

    image.update_column(:src_url, tile) if image.src_url == original
    image.board_images.where(display_image_url: original).update_all(display_image_url: tile)
  end
end
