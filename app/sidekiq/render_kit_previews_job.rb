# Rebuilds a kit page's preview gallery from its first uploaded document.
#
# Enqueued whenever the documents on a KitPage change. The whole set is
# replaced rather than appended to: the previews are a picture OF the current
# download, so a stale page from a document that has been removed is worse than
# no picture at all.
class RenderKitPreviewsJob
  include Sidekiq::Job

  sidekiq_options retry: 2

  def perform(kit_page_id)
    kit_page = KitPage.find_by(id: kit_page_id)
    return if kit_page.nil?

    kit_page.purge_preview_images!

    document = kit_page.ordered_documents.first
    return if document.nil?
    return unless KitPages::DocumentPreviewRenderer.available?

    bytes = document.download
    KitPages::DocumentPreviewRenderer.new.call(bytes).each_with_index do |png, index|
      kit_page.attach_preview_image!(bytes: png, page: index + 1)
    end
  rescue ActiveStorage::FileNotFoundError => e
    # The blob is gone from storage. Nothing to render and nothing to retry.
    Rails.logger.warn("[RenderKitPreviewsJob] kit_page=#{kit_page_id} missing blob: #{e.message}")
  end
end
