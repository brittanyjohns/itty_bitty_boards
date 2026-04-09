class PreprocessDocTileVariantsJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 1

  def perform(doc_ids)
    processed_count = 0
    skipped_count = 0
    failed_count = 0

    Doc.includes(image_attachment: :blob).where(id: doc_ids).find_each do |doc|
      begin
        unless doc.image.attached? && doc.image.variable?
          skipped_count += 1
          next
        end

        if doc.tile_variant_processed?
          skipped_count += 1
          next
        end

        doc.tile_variant.processed
        processed_count += 1
      rescue => e
        failed_count += 1
        Rails.logger.error("[tile-variant] failed for Doc #{doc.id}: #{e.message}")
      end
    end

    Rails.logger.info(
      "[tile-variant-batch] done processed=#{processed_count} skipped=#{skipped_count} failed=#{failed_count} total=#{doc_ids.size}"
    )
  end
end
