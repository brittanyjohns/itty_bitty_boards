# Rebuilds a kit page's preview gallery from EVERY uploaded document.
#
# Enqueued whenever the documents on a KitPage change. The whole set is
# replaced rather than appended to: the previews are a picture OF the current
# download, so a stale page from a document that has been removed is worse than
# no picture at all.
#
# The replacement is render-then-purge, not purge-then-render, and the batch
# stamp is what makes that possible: the new set is built alongside the old one
# and only then does the old one go. Purging first blanks a live public gallery
# for as long as the job runs — a second at two pages, a minute at fifty.
class RenderKitPreviewsJob
  include Sidekiq::Job

  sidekiq_options retry: 2

  def perform(kit_page_id)
    kit_page = KitPage.find_by(id: kit_page_id)
    return if kit_page.nil?

    documents = kit_page.ordered_documents
    return kit_page.purge_preview_images! if documents.empty?
    return unless KitPages::DocumentPreviewRenderer.available?

    batch = SecureRandom.hex(4)
    renderer = KitPages::DocumentPreviewRenderer.new
    rendered = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    documents.each do |document|
      renderer.each_page(document.download) do |png, index|
        kit_page.attach_preview_image!(
          bytes: png,
          page: index + 1,
          document_id: document.blob_id,
          batch: batch,
        )
        rendered += 1
      end
    end

    kit_page.purge_preview_images!(except_batch: batch)

    # The cost of this job scales with MAX_DOCUMENTS x preview_render_limit, so
    # it is worth being able to see what a page actually costs before a very
    # long PDF makes it a problem.
    Rails.logger.info(
      "[RenderKitPreviewsJob] kit_page=#{kit_page_id} documents=#{documents.size} " \
      "pages=#{rendered} seconds=#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)}"
    )
  rescue ActiveStorage::FileNotFoundError => e
    # The blob is gone from storage. Nothing to render and nothing to retry.
    Rails.logger.warn("[RenderKitPreviewsJob] kit_page=#{kit_page_id} missing blob: #{e.message}")
  end
end
